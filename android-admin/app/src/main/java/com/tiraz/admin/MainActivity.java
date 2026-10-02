package com.tiraz.admin;

import android.app.Activity;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

public class MainActivity extends Activity {
  private WebView web;
  private ValueCallback<Uri[]> filePathCallback;
  private static final int FILE_CHOOSER = 1001;

  @Override
  public void onCreate(Bundle state) {
    super.onCreate(state);

    web = new WebView(this);
    setContentView(web);

    WebSettings settings = web.getSettings();
    settings.setJavaScriptEnabled(true);
    settings.setDomStorageEnabled(true);
    settings.setDatabaseEnabled(true);
    settings.setAllowFileAccess(true);
    settings.setMediaPlaybackRequiresUserGesture(false);

    web.setWebViewClient(new WebViewClient() {
      @Override
      public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
        Uri uri = request.getUrl();
        String host = uri.getHost();
        if (host != null && (host.equals("3c5-o.github.io") || host.endsWith("supabase.co"))) {
          return false;
        }
        startActivity(new Intent(Intent.ACTION_VIEW, uri));
        return true;
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
          startActivityForResult(params.createIntent(), FILE_CHOOSER);
          return true;
        } catch (Exception error) {
          filePathCallback = null;
          return false;
        }
      }
    });

    web.loadUrl("https://3c5-o.github.io/tiraz-store/admin/");
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