import UIKit
import Capacitor

// 讓 iPhone 可以從螢幕左邊緣往右滑，回到上一頁（跟一般 App 一樣）
class MainViewController: CAPBridgeViewController {
    override func capacitorDidLoad() {
        super.capacitorDidLoad()
        webView?.allowsBackForwardNavigationGestures = true
    }
}
