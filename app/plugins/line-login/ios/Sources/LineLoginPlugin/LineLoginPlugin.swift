import Foundation
import UIKit
import Capacitor
import LineSDK

// 用 LINE 官方 SDK 登入：有裝 LINE 就直接跳 LINE App 確認，沒裝才開網頁
// login({ channelId, nonce }) → { idToken, displayName, pictureUrl }
// nonce 要傳「雜湊後」的值，LINE 會寫進 ID token；原始值由網頁交給 Supabase 核對
@objc(LineLoginPlugin)
public class LineLoginPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "LineLoginPlugin"
    public let jsName = "LineLogin"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "login", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "logout", returnType: CAPPluginReturnPromise)
    ]

    override public func load() {
        // LINE App 授權完會用 line3rdp.<bundle id>:// 跳回來，交給 SDK 處理
        NotificationCenter.default.addObserver(self, selector: #selector(handleOpenURL(_:)), name: .capacitorOpenURL, object: nil)
        // 有設定通用連結時，LINE 會用 https://wangmiaotw.com/line-auth/… 直接跳回（不會出現「Open this app?」）
        NotificationCenter.default.addObserver(self, selector: #selector(handleUniversalLink(_:)), name: .capacitorOpenUniversalLink, object: nil)
    }

    @objc func handleUniversalLink(_ note: Notification) {
        guard let obj = note.object as? [String: Any], let url = obj["url"] as? URL else { return }
        guard url.path.hasPrefix("/line-auth") else { return }
        Task { @MainActor in
            _ = LoginManager.shared.application(UIApplication.shared, open: url)
        }
    }

    @objc func handleOpenURL(_ note: Notification) {
        guard let obj = note.object as? [String: Any], let url = obj["url"] as? URL else { return }
        guard url.scheme?.hasPrefix("line3rdp.") == true else { return }
        Task { @MainActor in
            _ = LoginManager.shared.application(UIApplication.shared, open: url)
        }
    }

    @objc func login(_ call: CAPPluginCall) {
        guard let channelId = call.getString("channelId"), !channelId.isEmpty else {
            call.reject("缺少 channelId"); return
        }
        let nonce = call.getString("nonce")
        Task { @MainActor in
            let lm = LoginManager.shared
            if !lm.isSetupFinished {
                let ul = call.getString("universalLink").flatMap { URL(string: $0) }
                lm.setup(channelID: channelId, universalLinkURL: ul)
            }
            var params = LoginManager.Parameters()
            params.IDTokenNonce = nonce
            params.allowRecreatingLoginProcess = true
            lm.login(permissions: [.openID, .profile], in: self.bridge?.viewController, parameters: params) { result in
                switch result {
                case .success(let r):
                    guard let token = r.accessToken.IDTokenRaw else {
                        call.reject("沒有拿到 LINE 的登入憑證"); return
                    }
                    var ret: [String: Any] = ["idToken": token]
                    if let p = r.userProfile {
                        ret["displayName"] = p.displayName
                        if let u = p.pictureURL { ret["pictureUrl"] = u.absoluteString }
                    }
                    call.resolve(ret)
                case .failure(let e):
                    if e.isUserCancelled {
                        call.reject("cancel", "CANCELLED")
                    } else {
                        call.reject(e.localizedDescription, "LINE_ERROR")
                    }
                }
            }
        }
    }

    @objc func logout(_ call: CAPPluginCall) {
        Task { @MainActor in
            guard LoginManager.shared.isSetupFinished, LoginManager.shared.isAuthorized else { call.resolve(); return }
            LoginManager.shared.logout { _ in call.resolve() }
        }
    }
}
