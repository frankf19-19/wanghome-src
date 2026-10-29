package com.wangmiaotw.linelogin;

import android.content.Intent;
import androidx.activity.result.ActivityResult;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.ActivityCallback;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.linecorp.linesdk.LineApiResponseCode;
import com.linecorp.linesdk.LineIdToken;
import com.linecorp.linesdk.LineProfile;
import com.linecorp.linesdk.Scope;
import com.linecorp.linesdk.auth.LineAuthenticationParams;
import com.linecorp.linesdk.auth.LineLoginApi;
import com.linecorp.linesdk.auth.LineLoginResult;
import java.util.Arrays;

// 用 LINE 官方 SDK 登入：有裝 LINE 就直接跳 LINE App 確認，沒裝才開網頁
// login({ channelId, nonce }) → { idToken, displayName, pictureUrl }
@CapacitorPlugin(name = "LineLogin")
public class LineLoginPlugin extends Plugin {

    @PluginMethod
    public void login(PluginCall call) {
        String channelId = call.getString("channelId");
        if (channelId == null || channelId.isEmpty()) {
            call.reject("缺少 channelId");
            return;
        }
        LineAuthenticationParams.Builder b = new LineAuthenticationParams.Builder()
            .scopes(Arrays.asList(Scope.PROFILE, Scope.OPENID_CONNECT));
        String nonce = call.getString("nonce");
        if (nonce != null && !nonce.isEmpty()) b.nonce(nonce);
        Intent intent = LineLoginApi.getLoginIntent(getContext(), channelId, b.build());
        startActivityForResult(call, intent, "onLineResult");
    }

    @ActivityCallback
    private void onLineResult(PluginCall call, ActivityResult ar) {
        if (call == null) return;
        Intent data = ar.getData();
        if (data == null) {
            call.reject("cancel", "CANCELLED");
            return;
        }
        LineLoginResult r = LineLoginApi.getLoginResultFromIntent(data);
        if (r.getResponseCode() == LineApiResponseCode.SUCCESS) {
            LineIdToken t = r.getLineIdToken();
            if (t == null) {
                call.reject("沒有拿到 LINE 的登入憑證");
                return;
            }
            JSObject ret = new JSObject();
            ret.put("idToken", t.getRawString());
            LineProfile p = r.getLineProfile();
            if (p != null) {
                ret.put("displayName", p.getDisplayName());
                if (p.getPictureUrl() != null) ret.put("pictureUrl", p.getPictureUrl().toString());
            }
            call.resolve(ret);
        } else if (r.getResponseCode() == LineApiResponseCode.CANCEL) {
            call.reject("cancel", "CANCELLED");
        } else {
            call.reject(String.valueOf(r.getErrorData()), "LINE_ERROR");
        }
    }

    @PluginMethod
    public void logout(PluginCall call) {
        call.resolve();
    }
}
