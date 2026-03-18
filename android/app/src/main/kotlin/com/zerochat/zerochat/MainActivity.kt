package com.zerochat.zerochat

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
	private val wakeLockChannel = "zerochat/wakelock"
	private val mainHandler = Handler(Looper.getMainLooper())
	private var wakeLock: PowerManager.WakeLock? = null
	private var releaseRunnable: Runnable? = null

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)

		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, wakeLockChannel)
			.setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
				when (call.method) {
					"acquireFor" -> {
						val durationMs = call.argument<Int>("durationMs") ?: 10000
						acquireWakeLockFor(durationMs)
						result.success(null)
					}
					"release" -> {
						releaseWakeLock()
						result.success(null)
					}
					else -> result.notImplemented()
				}
			}
	}

	override fun onDestroy() {
		releaseWakeLock()
		super.onDestroy()
	}

	private fun acquireWakeLockFor(durationMs: Int) {
		val safeDuration = durationMs.coerceIn(3000, 120000).toLong()
		val lock = wakeLock ?: run {
			val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
			powerManager.newWakeLock(
				PowerManager.PARTIAL_WAKE_LOCK,
				"$packageName:ZeroChatShortWakeLock"
			).apply {
				setReferenceCounted(false)
				wakeLock = this
			}
		}

		if (!lock.isHeld) {
			lock.acquire()
		}

		releaseRunnable?.let { mainHandler.removeCallbacks(it) }
		val runnable = Runnable { releaseWakeLock() }
		releaseRunnable = runnable
		mainHandler.postDelayed(runnable, safeDuration)
	}

	private fun releaseWakeLock() {
		releaseRunnable?.let { mainHandler.removeCallbacks(it) }
		releaseRunnable = null

		val lock = wakeLock
		if (lock != null && lock.isHeld) {
			try {
				lock.release()
			} catch (_: RuntimeException) {
			}
		}
	}
}
