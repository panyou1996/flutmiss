package com.github.lingyan000.fluxdo

import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.os.Process
import android.util.Base64
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.EOFException
import java.io.IOException
import java.net.URI
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.atomic.AtomicInteger

class AndroidCdpBridge {
    companion object {
        private const val TAG = "AndroidCdp"
        private const val SOCKET_PREFIX = "webview_devtools_remote_"
        private const val WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        private const val TARGET_QUERY_MAX_ATTEMPTS = 12
        private const val TARGET_QUERY_RETRY_DELAY_MS = 150L
    }

    private val nextId = AtomicInteger(1)

    fun isAvailable(): Boolean {
        return try {
            val targets = queryTargets()
            Log.i(TAG, "isAvailable targets=${targets.size}")
            targets.isNotEmpty()
        } catch (e: Exception) {
            Log.w(TAG, "CDP unavailable", e)
            false
        }
    }

    fun awaitTargetReady(timeoutMs: Long): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs.coerceAtLeast(0)
        var attempt = 0
        while (true) {
            attempt++
            val targets = queryTargetsOnce()
            Log.i(TAG, "awaitTargetReady attempt=$attempt parsed=${targets.size}")
            if (targets.isNotEmpty()) {
                return true
            }

            val remaining = deadline - System.currentTimeMillis()
            if (remaining <= 0) {
                Log.i(TAG, "awaitTargetReady timeout after attempt=$attempt")
                return false
            }

            Thread.sleep(minOf(TARGET_QUERY_RETRY_DELAY_MS, remaining))
        }
    }

    fun getCookies(urls: List<String>): Map<String, Any?> {
        Log.i(TAG, "getCookies urls=$urls")
        val targets = queryTargets()
        Log.i(TAG, "getCookies discoveredTargets=${targets.size}")
        val target = pickTarget(targets, urls)
            ?: return mapOf(
                "ok" to false,
                "error" to "No matching devtools target",
                "targets" to targets.map { it.toMap() },
            ).also {
                Log.w(TAG, "No matching devtools target for urls=$urls targets=${targets.map { t -> t.url }}")
            }

        Log.i(TAG, "Selected target id=${target.id} type=${target.type} title=${target.title} url=${target.url} ws=${target.webSocketPath}")

        val ws = openWebSocket(target.webSocketPath)
        try {
            call(ws, "Network.enable", JSONObject())
            Log.i(TAG, "Network.enable succeeded for target=${target.id}")
            val params = JSONObject().put("urls", JSONArray(urls))
            val response = call(ws, "Network.getCookies", params)
            val cookies = response.optJSONArray("cookies") ?: JSONArray()
            Log.i(TAG, "Network.getCookies returned count=${cookies.length()} for target=${target.id}")
            return mapOf(
                "ok" to true,
                "target" to target.toMap(),
                "cookies" to jsonArrayToList(cookies),
                "count" to cookies.length(),
            )
        } finally {
            ws.close()
        }
    }

    fun setCookie(params: Map<String, Any?>): Map<String, Any?> {
        Log.i(TAG, "setCookie paramsKeys=${params.keys}")
        val target = queryTargets().firstOrNull { it.type == "page" }
            ?: return mapOf(
                "ok" to false,
                "error" to "No page target available",
            )

        Log.i(TAG, "setCookie selected target=${target.id} url=${target.url}")
        val ws = openWebSocket(target.webSocketPath)
        try {
            call(ws, "Network.enable", JSONObject())
            val result = call(ws, "Network.setCookie", params.toJsonObject())
            val success = result.optBoolean("success", false)
            Log.i(TAG, "Network.setCookie success=$success")
            return mapOf(
                "ok" to success,
                "result" to jsonObjectToMap(result),
            )
        } finally {
            ws.close()
        }
    }

    fun deleteCookies(params: Map<String, Any?>): Map<String, Any?> {
        Log.i(TAG, "deleteCookies paramsKeys=${params.keys}")
        val target = queryTargets().firstOrNull { it.type == "page" }
            ?: return mapOf(
                "ok" to false,
                "error" to "No page target available",
            )

        val ws = openWebSocket(target.webSocketPath)
        try {
            call(ws, "Network.enable", JSONObject())
            val result = call(ws, "Network.deleteCookies", params.toJsonObject())
            Log.i(TAG, "Network.deleteCookies succeeded")
            return mapOf(
                "ok" to true,
                "result" to jsonObjectToMap(result),
            )
        } finally {
            ws.close()
        }
    }

    private fun queryTargets(): List<DevToolsTarget> {
        repeat(TARGET_QUERY_MAX_ATTEMPTS) { attempt ->
            val targets = queryTargetsOnce()
            Log.i(TAG, "queryTargets attempt=${attempt + 1}/$TARGET_QUERY_MAX_ATTEMPTS parsed=${targets.size}")
            if (targets.isNotEmpty() || attempt == TARGET_QUERY_MAX_ATTEMPTS - 1) {
                return targets
            }

            Log.i(TAG, "queryTargets empty, waiting ${TARGET_QUERY_RETRY_DELAY_MS}ms before retry")
            Thread.sleep(TARGET_QUERY_RETRY_DELAY_MS)
        }

        return emptyList()
    }

    private fun queryTargetsOnce(): List<DevToolsTarget> {
        val response = sendHttpRequest("/json/list")
        Log.i(TAG, "queryTargetsOnce status=${response.statusCode} bodyLength=${response.body.length}")
        val json = JSONArray(response.body)
        val targets = mutableListOf<DevToolsTarget>()
        for (i in 0 until json.length()) {
            val item = json.optJSONObject(i) ?: continue
            DevToolsTarget.fromJson(item)?.let(targets::add)
        }
        return targets
    }

    private fun pickTarget(targets: List<DevToolsTarget>, urls: List<String>): DevToolsTarget? {
        val candidateHosts = urls.mapNotNull {
            try {
                URI(it).host?.lowercase()
            } catch (_: Exception) {
                null
            }
        }.toSet()

        return targets.firstOrNull { target ->
            val host = try {
                URI(target.url).host?.lowercase()
            } catch (_: Exception) {
                null
            }
            target.type == "page" && host != null && candidateHosts.contains(host)
        } ?: targets.firstOrNull { it.type == "page" }
    }

    private fun sendHttpRequest(path: String): HttpResponse {
        Log.i(TAG, "HTTP request path=$path")
        val socket = connectSocket()
        socket.soTimeout = 5000
        try {
            val input = BufferedInputStream(socket.inputStream)
            val output = BufferedOutputStream(socket.outputStream)
            val request = buildString {
                append("GET $path HTTP/1.1\r\n")
                append("Host: localhost\r\n")
                append("Connection: close\r\n")
                append("\r\n")
            }
            output.write(request.toByteArray(StandardCharsets.UTF_8))
            output.flush()
            return readHttpResponse(input)
        } finally {
            socket.close()
        }
    }

    private fun openWebSocket(path: String): WebSocketConnection {
        Log.i(TAG, "Opening websocket path=$path")
        val socket = connectSocket()
        socket.soTimeout = 5000
        val input = BufferedInputStream(socket.inputStream)
        val output = BufferedOutputStream(socket.outputStream)

        val keyBytes = ByteArray(16)
        SecureRandom().nextBytes(keyBytes)
        val key = Base64.encodeToString(keyBytes, Base64.NO_WRAP)
        val request = buildString {
            append("GET $path HTTP/1.1\r\n")
            append("Host: localhost\r\n")
            append("Upgrade: websocket\r\n")
            append("Connection: Upgrade\r\n")
            append("Sec-WebSocket-Key: $key\r\n")
            append("Sec-WebSocket-Version: 13\r\n")
            append("\r\n")
        }
        output.write(request.toByteArray(StandardCharsets.UTF_8))
        output.flush()

        val response = readHttpResponse(input)
        Log.i(TAG, "WebSocket handshake status=${response.statusCode} headers=${response.headers.keys}")
        if (response.statusCode != 101) {
            socket.close()
            throw IllegalStateException("WebSocket handshake failed: ${response.statusCode}")
        }

        val expectedAccept = Base64.encodeToString(
            MessageDigest.getInstance("SHA-1")
                .digest((key + WS_GUID).toByteArray(StandardCharsets.UTF_8)),
            Base64.NO_WRAP,
        )
        val actualAccept = response.headers["sec-websocket-accept"]
        if (actualAccept != expectedAccept) {
            socket.close()
            throw IllegalStateException("Invalid Sec-WebSocket-Accept")
        }

        Log.i(TAG, "WebSocket handshake succeeded path=$path")

        return WebSocketConnection(socket, input, output)
    }

    private fun call(ws: WebSocketConnection, method: String, params: JSONObject): JSONObject {
        val id = nextId.getAndIncrement()
        val payload = JSONObject()
            .put("id", id)
            .put("method", method)
            .put("params", params)
        ws.writeText(payload.toString())

        while (true) {
            val frame = ws.readText() ?: throw EOFException("WebSocket closed")
            val json = JSONObject(frame)
            if (json.optInt("id") != id) {
                continue
            }
            if (json.has("error")) {
                throw IllegalStateException("CDP error: ${json.getJSONObject("error")}")
            }
            return json.optJSONObject("result") ?: JSONObject()
        }
    }

    private fun connectSocket(): LocalSocket {
        val socket = LocalSocket()
        val address = LocalSocketAddress(
            SOCKET_PREFIX + Process.myPid(),
            LocalSocketAddress.Namespace.ABSTRACT,
        )
        Log.i(TAG, "Connecting devtools socket name=${SOCKET_PREFIX + Process.myPid()}")
        socket.connect(address)
        return socket
    }

    private fun readHttpResponse(input: BufferedInputStream): HttpResponse {
        val headerBytes = ByteArrayOutputStream()
        var matched = 0
        val delimiter = byteArrayOf('\r'.code.toByte(), '\n'.code.toByte(), '\r'.code.toByte(), '\n'.code.toByte())
        while (matched < delimiter.size) {
            val b = readByteWithRetry(input)
            if (b == -1) throw EOFException("Unexpected EOF while reading headers")
            headerBytes.write(b)
            matched = if (b.toByte() == delimiter[matched]) matched + 1 else if (b.toByte() == delimiter[0]) 1 else 0
        }

        val headerText = headerBytes.toString(StandardCharsets.UTF_8.name())
        val lines = headerText.split("\r\n").filter { it.isNotEmpty() }
        val statusCode = lines.firstOrNull()?.split(' ')?.getOrNull(1)?.toIntOrNull() ?: 0
        val headers = mutableMapOf<String, String>()
        for (line in lines.drop(1)) {
            val index = line.indexOf(':')
            if (index <= 0) continue
            headers[line.substring(0, index).trim().lowercase()] = line.substring(index + 1).trim()
        }

        val contentLength = headers["content-length"]?.toIntOrNull()
        val connectionHeader = headers["connection"]?.lowercase()
        val upgradeHeader = headers["upgrade"]?.lowercase()
        val isWebSocketUpgrade =
            statusCode == 101 ||
            (connectionHeader?.contains("upgrade") == true && upgradeHeader == "websocket")

        val bodyBytes = ByteArrayOutputStream()
        if (isWebSocketUpgrade) {
            return HttpResponse(statusCode, headers, "")
        } else if (contentLength != null) {
            val buffer = ByteArray(contentLength)
            var offset = 0
            while (offset < contentLength) {
                val count = readIntoBufferWithRetry(input, buffer, offset, contentLength - offset)
                if (count == -1) throw EOFException("Unexpected EOF while reading body")
                offset += count
            }
            bodyBytes.write(buffer)
        } else {
            val buffer = ByteArray(4096)
            while (true) {
                val count = try {
                    readIntoBufferWithRetry(input, buffer, 0, buffer.size)
                } catch (_: EOFException) {
                    -1
                }
                if (count == -1) break
                bodyBytes.write(buffer, 0, count)
            }
        }

        return HttpResponse(statusCode, headers, bodyBytes.toString(StandardCharsets.UTF_8.name()))
    }

    private fun jsonArrayToList(array: JSONArray): List<Any?> {
        val list = mutableListOf<Any?>()
        for (i in 0 until array.length()) {
            list.add(jsonValueToAny(array.get(i)))
        }
        return list
    }

    private fun jsonObjectToMap(obj: JSONObject): Map<String, Any?> {
        val map = linkedMapOf<String, Any?>()
        val keys = obj.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            map[key] = jsonValueToAny(obj.get(key))
        }
        return map
    }

    private fun jsonValueToAny(value: Any?): Any? {
        return when (value) {
            null, JSONObject.NULL -> null
            is JSONObject -> jsonObjectToMap(value)
            is JSONArray -> jsonArrayToList(value)
            else -> value
        }
    }

    private fun Map<String, Any?>.toJsonObject(): JSONObject {
        val obj = JSONObject()
        for ((key, value) in this) {
            obj.put(key, anyToJsonValue(value))
        }
        return obj
    }

    private fun anyToJsonValue(value: Any?): Any? {
        return when (value) {
            null -> JSONObject.NULL
            is Map<*, *> -> {
                val nested = JSONObject()
                value.forEach { (k, v) ->
                    if (k is String) nested.put(k, anyToJsonValue(v))
                }
                nested
            }
            is Iterable<*> -> {
                val array = JSONArray()
                value.forEach { array.put(anyToJsonValue(it)) }
                array
            }
            is Array<*> -> {
                val array = JSONArray()
                value.forEach { array.put(anyToJsonValue(it)) }
                array
            }
            else -> value
        }
    }

    data class HttpResponse(
        val statusCode: Int,
        val headers: Map<String, String>,
        val body: String,
    )

    data class DevToolsTarget(
        val id: String,
        val type: String,
        val title: String,
        val url: String,
        val webSocketPath: String,
    ) {
        fun toMap(): Map<String, Any?> = mapOf(
            "id" to id,
            "type" to type,
            "title" to title,
            "url" to url,
            "webSocketPath" to webSocketPath,
        )

        companion object {
            fun fromJson(obj: JSONObject): DevToolsTarget? {
                val id = obj.optString("id")
                val type = obj.optString("type")
                val title = obj.optString("title")
                val url = obj.optString("url")
                val webSocketDebuggerUrl = obj.optString("webSocketDebuggerUrl")
                if (id.isEmpty() || webSocketDebuggerUrl.isEmpty()) return null
                val path = try {
                    URI(webSocketDebuggerUrl).path
                } catch (_: Exception) {
                    return null
                }
                return DevToolsTarget(id, type, title, url, path)
            }
        }
    }

    inner class WebSocketConnection(
        private val socket: LocalSocket,
        private val input: BufferedInputStream,
        private val output: BufferedOutputStream,
    ) {
        fun writeText(text: String) {
            val payload = text.toByteArray(StandardCharsets.UTF_8)
            val mask = ByteArray(4)
            SecureRandom().nextBytes(mask)
            val frame = ByteArrayOutputStream()
            frame.write(0x81)
            when {
                payload.size <= 125 -> frame.write(0x80 or payload.size)
                payload.size <= 0xFFFF -> {
                    frame.write(0x80 or 126)
                    frame.write((payload.size shr 8) and 0xFF)
                    frame.write(payload.size and 0xFF)
                }
                else -> throw IllegalArgumentException("Payload too large")
            }
            frame.write(mask)
            payload.forEachIndexed { index, byte ->
                frame.write(byte.toInt() xor mask[index % 4].toInt())
            }
            output.write(frame.toByteArray())
            output.flush()
        }

        fun readText(): String? {
            while (true) {
                val first = readByteWithRetry(input)
                if (first == -1) return null
                val second = readByteWithRetry(input)
                if (second == -1) return null

                val opcode = first and 0x0F
                val masked = (second and 0x80) != 0
                var length = second and 0x7F
                if (length == 126) {
                    val lengthHigh = readByteWithRetry(input)
                    val lengthLow = readByteWithRetry(input)
                    length = (lengthHigh shl 8) or lengthLow
                } else if (length == 127) {
                    throw IllegalStateException("Unsupported websocket frame length")
                }

                val mask = if (masked) ByteArray(4).also { readFullyWithRetry(input, it) } else null
                val payload = ByteArray(length)
                var offset = 0
                while (offset < length) {
                    val count = readIntoBufferWithRetry(input, payload, offset, length - offset)
                    if (count == -1) throw EOFException("Unexpected EOF in websocket frame")
                    offset += count
                }
                if (mask != null) {
                    for (i in payload.indices) {
                        payload[i] = (payload[i].toInt() xor mask[i % 4].toInt()).toByte()
                    }
                }

                when (opcode) {
                    0x1 -> return payload.toString(StandardCharsets.UTF_8)
                    0x8 -> return null
                    0x9 -> writeControlFrame(0xA, payload)
                }
            }
        }

        private fun writeControlFrame(opcode: Int, payload: ByteArray) {
            val frame = ByteArrayOutputStream()
            frame.write(0x80 or opcode)
            frame.write(payload.size)
            frame.write(payload)
            output.write(frame.toByteArray())
            output.flush()
        }

        fun close() {
            try {
                writeControlFrame(0x8, byteArrayOf())
            } catch (_: Exception) {
            }
            socket.close()
        }
    }

    private fun readByteWithRetry(input: BufferedInputStream): Int {
        repeat(20) { attempt ->
            try {
                return input.read()
            } catch (e: IOException) {
                if (!isRetryable(e) || attempt == 19) throw e
                Thread.sleep(50)
            }
        }
        return -1
    }

    private fun readIntoBufferWithRetry(
        input: BufferedInputStream,
        buffer: ByteArray,
        offset: Int,
        length: Int,
    ): Int {
        repeat(20) { attempt ->
            try {
                return input.read(buffer, offset, length)
            } catch (e: IOException) {
                if (!isRetryable(e) || attempt == 19) throw e
                Thread.sleep(50)
            }
        }
        return -1
    }

    private fun readFullyWithRetry(input: BufferedInputStream, buffer: ByteArray) {
        var offset = 0
        while (offset < buffer.size) {
            val count = readIntoBufferWithRetry(input, buffer, offset, buffer.size - offset)
            if (count == -1) throw EOFException("Unexpected EOF")
            offset += count
        }
    }

    private fun isRetryable(e: IOException): Boolean {
        val message = e.message ?: return false
        return message.contains("Try again", ignoreCase = true)
    }
}
