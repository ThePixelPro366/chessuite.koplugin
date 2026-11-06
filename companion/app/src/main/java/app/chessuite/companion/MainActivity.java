package app.chessuite.companion;

import android.app.Activity;
import android.graphics.Typeface;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.ViewGroup;
import android.webkit.CookieManager;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;

/**
 * Logs in to Lichess in a WebView, the normal way (Lichess' own login page,
 * with its bot check), then hands the Lichess session to the Chessuite
 * KOReader plugin on the e-reader, which asked for it with a QR code.
 *
 * The e-reader runs a small web server on the local network while it waits;
 * the pairing link is chessuite://pair?h=HOST&p=PORT&c=CODE (or the e-reader's
 * own http://HOST:PORT/pair?c=CODE page, pasted in).
 */
public class MainActivity extends Activity {
    private static final String LICHESS = "https://lichess.org";
    private final Handler main = new Handler(Looper.getMainLooper());

    private String host;
    private int port;
    private String code;
    private boolean sent;

    private TextView status;
    private WebView web;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        if (!readPairing(getIntent() != null ? getIntent().getData() : null)) {
            showStart(null);
        } else {
            showLogin();
        }
    }

    @Override
    protected void onNewIntent(android.content.Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        if (readPairing(intent.getData())) showLogin();
    }

    /** chessuite://pair?h=..&p=..&c=.. or http://HOST:PORT/pair?c=.. */
    private boolean readPairing(Uri uri) {
        if (uri == null) return false;
        try {
            if ("chessuite".equals(uri.getScheme())) {
                host = uri.getQueryParameter("h");
                port = Integer.parseInt(uri.getQueryParameter("p"));
            } else if ("http".equals(uri.getScheme())) {
                host = uri.getHost();
                port = uri.getPort() > 0 ? uri.getPort() : 80;
            } else {
                return false;
            }
            code = uri.getQueryParameter("c");
            sent = false;
            return host != null && !host.isEmpty() && code != null && !code.isEmpty();
        } catch (RuntimeException e) {
            return false;
        }
    }

    // Screens ---------------------------------------------------------------

    private LinearLayout column() {
        LinearLayout col = new LinearLayout(this);
        col.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(16);
        col.setPadding(pad, pad, pad, pad);
        return col;
    }

    private TextView text(String s, int sp, boolean bold) {
        TextView t = new TextView(this);
        t.setText(s);
        t.setTextSize(sp);
        if (bold) t.setTypeface(Typeface.DEFAULT_BOLD);
        t.setPadding(0, 0, 0, dp(12));
        return t;
    }

    private int dp(int v) {
        return Math.round(v * getResources().getDisplayMetrics().density);
    }

    /** Explains how to start, with a field for the e-reader's address. */
    private void showStart(String error) {
        LinearLayout col = column();
        col.addView(text("Chessuite Companion", 24, true));
        col.addView(text("On your e-reader, open Chessuite → Lichess account → Connect phone for Lichess analysis, "
            + "then scan the QR code it shows with your camera and tap \"Open in Chessuite Companion\".\n\n"
            + "Or type the address shown under the QR code:", 16, false));
        if (error != null) {
            TextView e = text(error, 16, true);
            e.setTextColor(0xFFB00020);
            col.addView(e);
        }
        final EditText address = new EditText(this);
        address.setHint("http://192.168.1.20:8765/pair?c=…");
        address.setSingleLine(true);
        col.addView(address);
        Button go = new Button(this);
        go.setText("Connect");
        go.setOnClickListener(v -> {
            String s = address.getText().toString().trim();
            if (!s.startsWith("http")) s = "http://" + s;
            if (readPairing(Uri.parse(s))) showLogin();
            else showStart("That address does not look right. It ends with /pair?c=…");
        });
        col.addView(go);
        setContentView(col);
    }

    /** The Lichess login page; once logged in, the session goes to the e-reader. */
    private void showLogin() {
        LinearLayout col = new LinearLayout(this);
        col.setOrientation(LinearLayout.VERTICAL);
        status = text("Log in to Lichess below. Your login is then sent to your e-reader (" + host + ").", 15, false);
        status.setPadding(dp(12), dp(12), dp(12), dp(8));
        col.addView(status);

        CookieManager.getInstance().setAcceptCookie(true);
        web = new WebView(this);
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        CookieManager.getInstance().setAcceptThirdPartyCookies(web, true);
        web.setWebViewClient(new LoginClient());
        col.addView(web, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));
        setContentView(col);
        web.loadUrl(LICHESS + "/login");
    }

    /** After every page load: are we logged in yet? */
    private final class LoginClient extends WebViewClient {
        @Override
        public void onPageFinished(WebView view, String url) {
            checkLoggedIn();
        }
    }

    private void showDone(String user) {
        LinearLayout col = column();
        col.setGravity(Gravity.CENTER_HORIZONTAL);
        col.addView(text("Done!", 28, true));
        col.addView(text("Your e-reader is now logged in to Lichess as " + user + ". "
            + "Chessuite can now ask Lichess to analyse your games.\n\nYou can close this app.", 17, false));
        Button close = new Button(this);
        close.setText("Close");
        close.setOnClickListener(v -> finish());
        col.addView(close);
        setContentView(col);
    }

    // Login detection and hand-over ------------------------------------------

    /** Lichess pages show the username in #user_tag once logged in. */
    private void checkLoggedIn() {
        if (sent || web == null) return;
        web.evaluateJavascript(
            "(function(){var t=document.getElementById('user_tag');return t?t.textContent.trim():'';})()",
            value -> {
                String user = value == null ? "" : value.replace("\"", "").trim();
                if (!user.isEmpty() && !sent) {
                    sent = true;
                    send(user);
                }
            });
    }

    private String lichessSessionCookie() {
        String all = CookieManager.getInstance().getCookie(LICHESS);
        if (all == null) return null;
        for (String part : all.split(";")) {
            String p = part.trim();
            if (p.startsWith("lila2=")) return p.substring("lila2=".length());
        }
        return null;
    }

    private void send(final String user) {
        CookieManager.getInstance().flush();
        final String cookie = lichessSessionCookie();
        if (cookie == null) {
            sent = false;
            status.setText("Logged in, but the Lichess session was not found. Reload the page and try again.");
            return;
        }
        final String ua = web.getSettings().getUserAgentString();
        status.setText("Logged in as " + user + ". Sending the login to your e-reader…");
        new Thread(() -> {
            String result;
            try {
                result = post("http://" + host + ":" + port + "/pair",
                    "c=" + enc(code) + "&user=" + enc(user) + "&cookie=" + enc(cookie) + "&ua=" + enc(ua));
            } catch (Exception e) {
                result = "error: " + e.getMessage();
            }
            final String r = result;
            main.post(() -> {
                if (r.startsWith("ok")) {
                    showDone(user);
                } else {
                    sent = false;
                    status.setText("Could not reach the e-reader (" + r + "). Make sure both are on the same "
                        + "Wi-Fi and the QR code is still shown, then reload this page.");
                }
            });
        }).start();
    }

    private static String enc(String s) throws java.io.UnsupportedEncodingException {
        return URLEncoder.encode(s, "UTF-8");
    }

    private static String post(String url, String body) throws Exception {
        HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
        c.setConnectTimeout(8000);
        c.setReadTimeout(8000);
        c.setRequestMethod("POST");
        c.setDoOutput(true);
        c.setRequestProperty("Content-Type", "application/x-www-form-urlencoded");
        byte[] data = body.getBytes(StandardCharsets.UTF_8);
        c.setFixedLengthStreamingMode(data.length);
        try (OutputStream out = c.getOutputStream()) {
            out.write(data);
        }
        int code = c.getResponseCode();
        InputStream in = code < 400 ? c.getInputStream() : c.getErrorStream();
        ByteArrayOutputStream buf = new ByteArrayOutputStream();
        if (in != null) {
            byte[] b = new byte[1024];
            int n;
            while ((n = in.read(b)) > 0) buf.write(b, 0, n);
            in.close();
        }
        String text = buf.toString("UTF-8").trim();
        return code == 200 ? text : ("HTTP " + code + " " + text);
    }

    @Override
    public void onBackPressed() {
        if (web != null && web.canGoBack()) web.goBack();
        else super.onBackPressed();
    }
}
