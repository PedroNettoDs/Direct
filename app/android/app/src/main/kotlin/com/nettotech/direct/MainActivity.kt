package com.nettotech.direct

import android.os.Bundle
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.android.RenderMode
import java.lang.ref.WeakReference

// FragmentActivity: o BiometricPrompt da digital precisa dela.
class MainActivity : FlutterFragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        SecureWindow.applyWindow(this)
        CoreEngine.activity = WeakReference(this)
        super.onCreate(savedInstanceState)
    }

    // Engine em cache: sobrevive à Activity enquanto o processo viver.
    override fun getCachedEngineId(): String {
        CoreEngine.get(this)
        return CoreEngine.ID
    }

    // TextureView: com SurfaceView, o Impeller/OpenGLES caía (SIGSEGV na thread
    // raster deste engine) ao ir para a tela inicial com o teclado da bolha aberto.
    override fun getRenderMode() = RenderMode.texture

    override fun onPostResume() {
        super.onPostResume()
        CoreEngine.activity = WeakReference(this)
        SecureWindow.applyViews(this)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == Bubbles.PERMISSION_REQUEST) {
            CoreEngine.permissionResult?.success(null)
            CoreEngine.permissionResult = null
        }
    }
}
