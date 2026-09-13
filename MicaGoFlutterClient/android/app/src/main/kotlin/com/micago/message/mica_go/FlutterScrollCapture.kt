package com.micago.message.mica_go

import android.graphics.Bitmap
import android.graphics.Rect
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.view.Choreographer
import android.view.PixelCopy
import android.view.ScrollCaptureCallback
import android.view.ScrollCaptureSession
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import android.view.Window
import androidx.annotation.RequiresApi
import io.flutter.embedding.android.FlutterSurfaceView
import io.flutter.plugin.common.MethodChannel
import java.util.function.Consumer

/**
 * Android 12+ "Capture more" support. Flutter renders into a single surface, so
 * the system's scroll-capture search finds no native scrollable. Installed on
 * the FlutterView, this asks Dart (`ScrollCaptureService`) for the active
 * list's bounds, has it scroll one tile at a time, and copies the rendered
 * pixels into the capture session's surface.
 */
@RequiresApi(Build.VERSION_CODES.S)
class FlutterScrollCapture(
    private val window: Window,
    private val flutterView: View,
    private val channel: MethodChannel,
) : ScrollCaptureCallback {
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onScrollCaptureSearch(signal: CancellationSignal, onReady: Consumer<Rect>) {
        invoke("search", null) { value -> onReady.accept(rectOf(value) ?: Rect()) }
    }

    override fun onScrollCaptureStart(
        session: ScrollCaptureSession,
        signal: CancellationSignal,
        onReady: Runnable,
    ) {
        invoke("start", null) { onReady.run() }
    }

    override fun onScrollCaptureImageRequest(
        session: ScrollCaptureSession,
        signal: CancellationSignal,
        captureArea: Rect,
        onComplete: Consumer<Rect>,
    ) {
        val bounds = Rect(session.scrollBounds)
        val args = mapOf(
            "top" to captureArea.top,
            "bottom" to captureArea.bottom,
            "height" to bounds.height(),
        )
        invoke("request", args) { value ->
            val tile = value as? Map<*, *>
            val capturedTop = (tile?.get("capturedTop") as? Number)?.toInt() ?: 0
            val capturedBottom = (tile?.get("capturedBottom") as? Number)?.toInt() ?: 0
            val viewportTop = (tile?.get("viewportTop") as? Number)?.toInt() ?: 0
            if (signal.isCanceled || capturedBottom <= capturedTop) {
                onComplete.accept(Rect())
                return@invoke
            }
            // Dart has laid out and painted the new scroll position; give the
            // raster thread a vsync or two to present it before copying.
            afterFrames(2) {
                val source = Rect(
                    bounds.left,
                    bounds.top + capturedTop - viewportTop,
                    bounds.right,
                    bounds.top + capturedBottom - viewportTop,
                )
                copyInto(session, source) { copied ->
                    onComplete.accept(
                        if (copied) {
                            Rect(captureArea.left, capturedTop, captureArea.right, capturedBottom)
                        } else {
                            Rect()
                        },
                    )
                }
            }
        }
    }

    override fun onScrollCaptureEnd(onReady: Runnable) {
        invoke("end", null) { onReady.run() }
    }

    private fun invoke(method: String, args: Any?, onResult: (Any?) -> Unit) {
        channel.invokeMethod(method, args, object : MethodChannel.Result {
            override fun success(result: Any?) = onResult(result)
            override fun error(code: String, message: String?, details: Any?) = onResult(null)
            override fun notImplemented() = onResult(null)
        })
    }

    private fun afterFrames(count: Int, block: () -> Unit) {
        if (count <= 0) {
            block()
            return
        }
        Choreographer.getInstance().postFrameCallback { afterFrames(count - 1, block) }
    }

    /** [source] is in FlutterView coordinates. */
    private fun copyInto(session: ScrollCaptureSession, source: Rect, onDone: (Boolean) -> Unit) {
        if (source.isEmpty) {
            onDone(false)
            return
        }
        val bitmap = Bitmap.createBitmap(source.width(), source.height(), Bitmap.Config.ARGB_8888)
        val finished = PixelCopy.OnPixelCopyFinishedListener { result ->
            val copied = result == PixelCopy.SUCCESS && draw(session, bitmap)
            bitmap.recycle()
            onDone(copied)
        }
        try {
            // Flutter's frames live in their own SurfaceView layer, which a window
            // copy does not include. Without one (e.g. hybrid-composition
            // platform views are showing), the content is in the window surface.
            val surfaceView = findFlutterSurface(flutterView)
            if (surfaceView != null && surfaceView.holder.surface.isValid) {
                PixelCopy.request(surfaceView, offsetInto(surfaceView, source), bitmap, finished, mainHandler)
            } else {
                PixelCopy.request(window, offsetIntoWindow(source), bitmap, finished, mainHandler)
            }
        } catch (e: IllegalArgumentException) {
            bitmap.recycle()
            onDone(false)
        }
    }

    private fun draw(session: ScrollCaptureSession, bitmap: Bitmap): Boolean {
        val surface = session.surface
        if (!surface.isValid) return false
        return try {
            val canvas = surface.lockHardwareCanvas()
            try {
                canvas.drawBitmap(bitmap, 0f, 0f, null)
            } finally {
                surface.unlockCanvasAndPost(canvas)
            }
            true
        } catch (e: RuntimeException) {
            false
        }
    }

    private fun offsetInto(target: View, rect: Rect): Rect {
        val from = IntArray(2).also { flutterView.getLocationInWindow(it) }
        val to = IntArray(2).also { target.getLocationInWindow(it) }
        return Rect(rect).apply { offset(from[0] - to[0], from[1] - to[1]) }
    }

    private fun offsetIntoWindow(rect: Rect): Rect {
        val from = IntArray(2).also { flutterView.getLocationInWindow(it) }
        return Rect(rect).apply { offset(from[0], from[1]) }
    }

    private fun findFlutterSurface(view: View): SurfaceView? {
        if (view is FlutterSurfaceView && view.visibility == View.VISIBLE) return view
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                findFlutterSurface(view.getChildAt(i))?.let { return it }
            }
        }
        return null
    }

    private fun rectOf(value: Any?): Rect? {
        val map = value as? Map<*, *> ?: return null
        fun edge(key: String) = (map[key] as? Number)?.toInt()
        val rect = Rect(
            edge("left") ?: return null,
            edge("top") ?: return null,
            edge("right") ?: return null,
            edge("bottom") ?: return null,
        )
        return if (rect.isEmpty) null else rect
    }
}
