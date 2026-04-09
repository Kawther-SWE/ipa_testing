package com.example.my_project

import android.Manifest
import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CLIPBOARD_CHANNEL = "my_project/clipboard"
        private const val PLAYBACK_CAPTURE_CHANNEL = "my_project/playback_capture"
        private const val PLAYBACK_AUDIO_STREAM_CHANNEL = "my_project/playback_audio_stream"
        private const val OVERLAY_ENGINE_CACHE_TAG = "myCachedEngine"
        private const val REQUEST_MEDIA_PROJECTION = 9813
        private const val PLAYBACK_SAMPLE_RATE = 16000
    }

    private var playbackCaptureChannel: MethodChannel? = null
    private var playbackAudioStreamChannel: EventChannel? = null
    private var playbackAudioSink: EventChannel.EventSink? = null

    private var mediaProjectionManager: MediaProjectionManager? = null
    private var mediaProjection: MediaProjection? = null
    private var audioRecord: AudioRecord? = null
    private var captureThread: Thread? = null
    private var pendingProjectionResult: MethodChannel.Result? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var isPlaybackCapturing = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        registerClipboardChannel(flutterEngine)
        registerPlaybackCaptureChannels(flutterEngine)
        ensureOverlayClipboardChannelRegistered()
    }

    override fun onResume() {
        super.onResume()
        ensureOverlayClipboardChannelRegistered()
    }

    override fun onDestroy() {
        stopPlaybackCaptureInternal(releaseProjection = true)
        pendingProjectionResult = null
        super.onDestroy()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQUEST_MEDIA_PROJECTION) {
            val callbackResult = pendingProjectionResult
            pendingProjectionResult = null

            if (resultCode != Activity.RESULT_OK || data == null) {
                callbackResult?.success(false)
                return
            }

            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                callbackResult?.error(
                    "UNSUPPORTED",
                    "Playback capture requires Android 10+",
                    null
                )
                return
            }

            mediaProjectionManager = getSystemService(Context.MEDIA_PROJECTION_SERVICE)
                    as MediaProjectionManager
            mediaProjection = mediaProjectionManager?.getMediaProjection(resultCode, data)
            mediaProjection?.registerCallback(projectionCallback, mainHandler)

            val started = startPlaybackCaptureInternal()
            callbackResult?.success(started)
            if (!started) {
                stopPlaybackCaptureInternal(releaseProjection = true)
            }
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun registerClipboardChannelOnOverlayEngine() {
        FlutterEngineCache.getInstance().get(OVERLAY_ENGINE_CACHE_TAG)?.let {
            registerClipboardChannel(it)
        }
    }

    private fun ensureOverlayClipboardChannelRegistered() {
        registerClipboardChannelOnOverlayEngine()
        repeat(5) { index ->
            mainHandler.postDelayed(
                { registerClipboardChannelOnOverlayEngine() },
                ((index + 1) * 400L)
            )
        }
    }

    private fun registerClipboardChannel(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CLIPBOARD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setText" -> {
                        val text = call.argument<String>("text")
                        if (text.isNullOrEmpty()) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        val clipboardManager =
                            applicationContext.getSystemService(Context.CLIPBOARD_SERVICE)
                                    as ClipboardManager
                        clipboardManager.setPrimaryClip(
                            ClipData.newPlainText("transcript", text),
                        )
                        result.success(true)
                    }

                    else -> result.notImplemented()
                }
            }
    }

    private fun registerPlaybackCaptureChannels(engine: FlutterEngine) {
        playbackCaptureChannel =
            MethodChannel(engine.dartExecutor.binaryMessenger, PLAYBACK_CAPTURE_CHANNEL)
        playbackCaptureChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "startPlaybackCapture" -> handleStartPlaybackCapture(result)
                "stopPlaybackCapture" -> {
                    stopPlaybackCaptureInternal()
                    result.success(true)
                }

                "isPlaybackCaptureRunning" -> result.success(isPlaybackCapturing)
                else -> result.notImplemented()
            }
        }

        playbackAudioStreamChannel =
            EventChannel(engine.dartExecutor.binaryMessenger, PLAYBACK_AUDIO_STREAM_CHANNEL)
        playbackAudioStreamChannel?.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                playbackAudioSink = events
            }

            override fun onCancel(arguments: Any?) {
                playbackAudioSink = null
            }
        })
    }

    private fun handleStartPlaybackCapture(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error("UNSUPPORTED", "Playback capture requires Android 10+", null)
            return
        }

        if (!hasRecordAudioPermission()) {
            result.error(
                "PERMISSION_DENIED",
                "RECORD_AUDIO permission is required for playback capture",
                null
            )
            return
        }

        if (isPlaybackCapturing) {
            result.success(true)
            return
        }

        if (mediaProjection != null) {
            result.success(startPlaybackCaptureInternal())
            return
        }

        mediaProjectionManager = getSystemService(Context.MEDIA_PROJECTION_SERVICE)
                as MediaProjectionManager
        val intent = mediaProjectionManager?.createScreenCaptureIntent()
        if (intent == null) {
            result.error("MEDIA_PROJECTION_ERROR", "Could not create capture intent", null)
            return
        }

        pendingProjectionResult = result
        try {
            startActivityForResult(intent, REQUEST_MEDIA_PROJECTION)
        } catch (error: Exception) {
            pendingProjectionResult = null
            result.error(
                "MEDIA_PROJECTION_ERROR",
                "Failed to launch capture permission: ${error.message}",
                null
            )
        }
    }

    private fun hasRecordAudioPermission(): Boolean {
        return ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.RECORD_AUDIO
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun startPlaybackCaptureInternal(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false
        val projection = mediaProjection ?: return false

        stopPlaybackCaptureInternal()

        val minBufferSize = AudioRecord.getMinBufferSize(
            PLAYBACK_SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT
        )
        if (minBufferSize <= 0) return false

        val bufferSize = minBufferSize * 4
        val captureConfig = AudioPlaybackCaptureConfiguration.Builder(projection)
            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
            .addMatchingUsage(AudioAttributes.USAGE_GAME)
            .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
            .build()

        val audioFormat = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(PLAYBACK_SAMPLE_RATE)
            .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
            .build()

        val record = AudioRecord.Builder()
            .setAudioPlaybackCaptureConfig(captureConfig)
            .setAudioFormat(audioFormat)
            .setBufferSizeInBytes(bufferSize)
            .build()

        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            return false
        }

        record.startRecording()
        if (record.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            record.release()
            return false
        }

        audioRecord = record
        isPlaybackCapturing = true

        captureThread = Thread {
            val buffer = ByteArray(bufferSize / 2)
            while (isPlaybackCapturing && !Thread.currentThread().isInterrupted) {
                val bytesRead = record.read(buffer, 0, buffer.size)
                if (bytesRead > 0) {
                    val chunk =
                        if (bytesRead == buffer.size) buffer.clone() else buffer.copyOf(bytesRead)
                    mainHandler.post {
                        playbackAudioSink?.success(chunk)
                    }
                } else if (
                    bytesRead == AudioRecord.ERROR_BAD_VALUE ||
                    bytesRead == AudioRecord.ERROR_INVALID_OPERATION
                ) {
                    mainHandler.post {
                        playbackAudioSink?.error(
                            "AUDIO_READ_ERROR",
                            "Playback capture read failed ($bytesRead)",
                            null
                        )
                    }
                    break
                }
            }
            if (isPlaybackCapturing) {
                mainHandler.post { stopPlaybackCaptureInternal() }
            }
        }.apply {
            name = "PlaybackAudioCapture"
            start()
        }

        return true
    }

    private fun stopPlaybackCaptureInternal(releaseProjection: Boolean = false) {
        isPlaybackCapturing = false

        captureThread?.interrupt()
        captureThread = null

        try {
            audioRecord?.stop()
        } catch (_: IllegalStateException) {
        }
        audioRecord?.release()
        audioRecord = null

        if (releaseProjection) {
            try {
                mediaProjection?.unregisterCallback(projectionCallback)
            } catch (_: Exception) {
            }
            mediaProjection?.stop()
            mediaProjection = null
        }
    }

    private val projectionCallback = object : MediaProjection.Callback() {
        override fun onStop() {
            mainHandler.post {
                stopPlaybackCaptureInternal()
                mediaProjection = null
            }
        }
    }
}
