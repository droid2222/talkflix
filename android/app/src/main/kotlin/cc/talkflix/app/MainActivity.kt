package cc.talkflix.app

import android.content.Intent
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun getInitialRoute(): String? {
        return mapIntentToRoute(intent) ?: super.getInitialRoute()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val route = mapIntentToRoute(intent) ?: return
        flutterEngine?.navigationChannel?.pushRoute(route)
    }

    private fun mapIntentToRoute(intent: Intent?): String? {
        if (intent?.action == Intent.ACTION_SEND) {
            val sharedText = intent.getStringExtra(Intent.EXTRA_TEXT)?.trim().orEmpty()
            if (sharedText.isNotEmpty()) {
                return "/app/talk?share=${Uri.encode(sharedText)}"
            }
        }
        return mapUriToRoute(intent?.data)
    }

    private fun mapUriToRoute(uri: Uri?): String? {
        if (uri == null) return null

        val segments = uri.pathSegments ?: emptyList()
        val scheme = uri.scheme?.lowercase() ?: return null
        val host = uri.host?.lowercase() ?: ""
        val isCustomScheme = scheme == "talkflix" && host == "app"
        val isUniversalLink =
            (scheme == "https" || scheme == "http") &&
                (host == "talkflix.cc" || host == "www.talkflix.cc")

        if (!isCustomScheme && !isUniversalLink) {
            return null
        }

        if (segments.size >= 2 && segments[0] == "s") {
            val token = segments[1].trim()
            if (token.isEmpty()) return null
            return "/s/$token"
        }

        val isLiveRoute =
            (segments.size >= 2 && segments[0] == "app" && segments[1] == "live") ||
                (segments.size >= 1 && segments[0] == "live")
        if (!isLiveRoute) {
            return null
        }

        val broadcastId =
            when {
                segments.size >= 3 && segments[0] == "live" -> segments[1].trim()
                segments.size >= 2 && segments[0] == "live" -> segments[1].trim()
                else -> uri.getQueryParameter("broadcastId")?.trim().orEmpty()
            }
        if (broadcastId.isEmpty()) {
            return "/app/live"
        }
        return "/app/live?broadcastId=$broadcastId"
    }
}
