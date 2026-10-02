package com.tiraz.admin;

import android.app.Activity;
import android.content.Intent;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import android.view.Gravity;
import android.view.View;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;
import android.widget.Toast;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;

public class MainActivity extends Activity {
  private WebView web;
  private View loadingView;
  private ValueCallback<Uri[]> filePathCallback;
  private static final int FILE_CHOOSER = 1001;
  private static final String BASE_URL = "https://3c5-o.github.io/tiraz-store/admin/";

  @Override
  public void onCreate(Bundle state) {
    super.onCreate(state);

    FrameLayout root = new FrameLayout(this);

    web = new WebView(this);
    root.addView(web, new FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT
    ));

    LinearLayout loading = new LinearLayout(this);
    loading.setOrientation(LinearLayout.VERTICAL);
    loading.setGravity(Gravity.CENTER);
    loading.setPadding(42, 42, 42, 42);
    loading.setBackgroundColor(Color.rgb(27, 18, 14));

    ImageView logo = new ImageView(this);
    logo.setImageResource(com.tiraz.admin.R.drawable.ic_tiraz_admin);
    LinearLayout.LayoutParams logoParams = new LinearLayout.LayoutParams(170, 170);
    logoParams.bottomMargin = 22;
    loading.addView(logo, logoParams);

    TextView title = new TextView(this);
    title.setText("إدارة طراز");
    title.setTextColor(Color.rgb(229, 200, 141));
    title.setTextSize(27);
    title.setGravity(Gravity.CENTER);
    loading.addView(title);

    TextView sub = new TextView(this);
    sub.setText("TIRAZ ADMIN");
    sub.setTextColor(Color.rgb(188, 171, 150));
    sub.setTextSize(12);
    sub.setGravity(Gravity.CENTER);
    LinearLayout.LayoutParams subParams = new LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.WRAP_CONTENT,
        LinearLayout.LayoutParams.WRAP_CONTENT
    );
    subParams.topMargin = 6;
    subParams.bottomMargin = 22;
    loading.addView(sub, subParams);

    ProgressBar progress = new ProgressBar(this);
    loading.addView(progress);

    loadingView = loading;
    root.addView(loading, new FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT
    ));

    setContentView(root);

    WebSettings settings = web.getSettings();
    settings.setJavaScriptEnabled(true);
    settings.setDomStorageEnabled(true);
    settings.setDatabaseEnabled(true);
    settings.setAllowFileAccess(true);
    settings.setAllowContentAccess(true);
    settings.setMediaPlaybackRequiresUserGesture(false);
    settings.setCacheMode(WebSettings.LOAD_NO_CACHE);
    settings.setSupportZoom(false);
    settings.setBuiltInZoomControls(false);
    settings.setDisplayZoomControls(false);
    settings.setJavaScriptCanOpenWindowsAutomatically(false);
    settings.setTextZoom(100);

    web.clearCache(true);
    web.clearHistory();

    web.setWebViewClient(new WebViewClient() {
      @Override
      public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
        Uri uri = request.getUrl();
        String host = uri.getHost();

        if (host != null && (
            host.equals("3c5-o.github.io") ||
            host.endsWith("supabase.co")
        )) {
          return false;
        }

        try {
          startActivity(new Intent(Intent.ACTION_VIEW, uri));
        } catch (Exception ignored) {
          Toast.makeText(MainActivity.this, "تعذر فتح الرابط", Toast.LENGTH_SHORT).show();
        }
        return true;
      }

      @Override
      public void onPageFinished(WebView view, String url) {
        super.onPageFinished(view, url);
        if (loadingView != null) loadingView.setVisibility(View.GONE);
      }

      @Override
      public void onReceivedError(
          WebView view,
          WebResourceRequest request,
          WebResourceError error
      ) {
        super.onReceivedError(view, request, error);
        if (request.isForMainFrame()) {
          if (loadingView != null) loadingView.setVisibility(View.GONE);
          Toast.makeText(
              MainActivity.this,
              "تعذر تحميل إدارة طراز. تحقق من الإنترنت ثم أعد فتح التطبيق.",
              Toast.LENGTH_LONG
          ).show();
        }
      }
    });

    web.setWebChromeClient(new WebChromeClient() {
      @Override
      public boolean onShowFileChooser(
          WebView webView,
          ValueCallback<Uri[]> callback,
          FileChooserParams params
      ) {
        if (filePathCallback != null) {
          filePathCallback.onReceiveValue(null);
        }
        filePathCallback = callback;

        try {
          Intent intent = params.createIntent();
          intent.addCategory(Intent.CATEGORY_OPENABLE);
          startActivityForResult(intent, FILE_CHOOSER);
          return true;
        } catch (Exception error) {
          filePathCallback = null;
          Toast.makeText(MainActivity.this, "تعذر فتح اختيار الملفات", Toast.LENGTH_SHORT).show();
          return false;
        }
      }
    });

    loadBundledAdmin();
  }

  private void loadBundledAdmin() {
    try {
      InputStream stream = getAssets().open("index.html");
      BufferedReader reader = new BufferedReader(new InputStreamReader(stream, "UTF-8"));
      StringBuilder html = new StringBuilder();
      String line;

      while ((line = reader.readLine()) != null) {
        html.append(line).append("\n");
      }

      reader.close();
      stream.close();

      web.loadDataWithBaseURL(
          BASE_URL,
          html.toString(),
          "text/html",
          "UTF-8",
          null
      );
    } catch (Exception error) {
      if (loadingView != null) loadingView.setVisibility(View.GONE);
      Toast.makeText(
          this,
          "تعذر تشغيل ملفات إدارة طراز.",
          Toast.LENGTH_LONG
      ).show();
    }
  }

  @Override
  protected void onActivityResult(int requestCode, int resultCode, Intent data) {
    super.onActivityResult(requestCode, resultCode, data);

    if (requestCode == FILE_CHOOSER && filePathCallback != null) {
      Uri[] result = WebChromeClient.FileChooserParams.parseResult(resultCode, data);
      filePathCallback.onReceiveValue(result);
      filePathCallback = null;
    }
  }

  @Override
  public void onBackPressed() {
    if (web != null && web.canGoBack()) {
      web.goBack();
    } else {
      super.onBackPressed();
    }
  }
}
