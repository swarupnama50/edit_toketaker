package com.example.token_taker

import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val channelName = "token_taker/whatsapp"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                if (call.method == "share") {
                    val paths = call.argument<List<String>>("paths") ?: emptyList()
                    val phone = call.argument<String>("phone") ?: ""
                    try {
                        result.success(shareToWhatsApp(paths, phone))
                    } catch (e: Exception) {
                        result.error("SHARE_FAILED", e.message, null)
                    }
                } else {
                    result.notImplemented()
                }
            }
    }

    private fun isInstalled(pkg: String): Boolean =
        try {
            packageManager.getPackageInfo(pkg, 0)
            true
        } catch (e: PackageManager.NameNotFoundException) {
            false
        }

    /** Returns false if WhatsApp is not installed. */
    private fun shareToWhatsApp(paths: List<String>, phone: String): Boolean {
        val pkg = when {
            isInstalled("com.whatsapp") -> "com.whatsapp"
            isInstalled("com.whatsapp.w4b") -> "com.whatsapp.w4b"
            else -> return false
        }
        if (paths.isEmpty()) return false

        val authority = "$packageName.tokentaker.fileprovider"
        val uris = ArrayList<Uri>()
        for (p in paths) {
            val uri = FileProvider.getUriForFile(this, authority, File(p))
            grantUriPermission(pkg, uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            uris.add(uri)
        }

        val intent =
            if (uris.size == 1) {
                Intent(Intent.ACTION_SEND).apply {
                    putExtra(Intent.EXTRA_STREAM, uris[0])
                }
            } else {
                Intent(Intent.ACTION_SEND_MULTIPLE).apply {
                    putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
                }
            }

        intent.type = "image/jpeg"
        intent.setPackage(pkg)
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)

        // Opens that chat directly. Without it, WhatsApp shows its contact list.
        if (phone.isNotEmpty()) {
            intent.putExtra("jid", "$phone@s.whatsapp.net")
        }

        startActivity(intent)
        return true
    }
}
