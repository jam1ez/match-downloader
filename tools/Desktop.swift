import AppKit
import WebKit

final class MatchDownloaderDesktop: NSObject, NSApplicationDelegate, WKUIDelegate, WKNavigationDelegate, WKDownloadDelegate {
    var window: NSWindow!
    var browser: WKWebView!
    var status: NSTextField!
    var spinner: NSProgressIndicator!
    var backend: Process?
    var quitting = false
    var checking = false
    var attempts = 0
    var timer: Timer?
    let root = Bundle.main.bundleURL.resolvingSymlinksInPath().deletingLastPathComponent()
    let address = URL(string: "http://127.0.0.1:8766/")!

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeMenu()
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        browser = WKWebView(frame: .zero, configuration: configuration)
        browser.uiDelegate = self
        browser.navigationDelegate = self
        window = NSWindow(contentRect: NSRect(x:0,y:0,width:1200,height:850), styleMask:[.titled,.closable,.miniaturizable,.resizable], backing:.buffered, defer:false)
        window.title = "Match Downloader"
        window.minSize = NSSize(width:850,height:650)
        window.center()
        window.contentView = browser
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
        showStatus("Starting Match Downloader…", detail:"Your match library will open automatically.")
        begin()
    }

    func makeMenu() {
        let menu=NSMenu()
        let appItem=NSMenuItem();menu.addItem(appItem)
        let appMenu=NSMenu();appItem.submenu=appMenu
        appMenu.addItem(withTitle:"Show Match Downloader",action:#selector(showWindow),keyEquivalent:"0").target=self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle:"Quit Match Downloader",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let editItem=NSMenuItem();editItem.title="Edit";menu.addItem(editItem)
        let edit=NSMenu(title:"Edit");editItem.submenu=edit
        for (title,action,key) in [("Cut","cut:","x"),("Copy","copy:","c"),("Paste","paste:","v"),("Select All","selectAll:","a")] {
            edit.addItem(withTitle:title,action:Selector(action),keyEquivalent:key)
        }
        let viewItem=NSMenuItem();viewItem.title="View";menu.addItem(viewItem)
        let view=NSMenu(title:"View");viewItem.submenu=view
        view.addItem(withTitle:"Reload",action:#selector(reload),keyEquivalent:"r").target=self
        NSApp.mainMenu=menu
    }

    @objc func showWindow() { window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true) }
    @objc func reload() { browser.reload() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {showWindow();return true}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool {false}
    func applicationWillTerminate(_ notification:Notification) {
        quitting=true;timer?.invalidate()
        if let process=backend,process.isRunning {process.terminate()}
    }

    func showStatus(_ title:String,detail:String) {
        let view=NSView()
        let heading=NSTextField(labelWithString:title)
        heading.font=NSFont.systemFont(ofSize:26,weight:.semibold)
        heading.alignment = .center
        heading.translatesAutoresizingMaskIntoConstraints=false
        let body=NSTextField(wrappingLabelWithString:detail)
        body.alignment = .center;body.textColor = .secondaryLabelColor
        body.translatesAutoresizingMaskIntoConstraints=false
        view.addSubview(heading);view.addSubview(body)
        NSLayoutConstraint.activate([
            heading.centerXAnchor.constraint(equalTo:view.centerXAnchor),heading.centerYAnchor.constraint(equalTo:view.centerYAnchor,constant:-28),
            heading.widthAnchor.constraint(lessThanOrEqualTo:view.widthAnchor,constant:-80),
            body.topAnchor.constraint(equalTo:heading.bottomAnchor,constant:16),body.centerXAnchor.constraint(equalTo:view.centerXAnchor),body.widthAnchor.constraint(equalToConstant:650)
        ])
        window.contentView=view
    }

    func health(_ callback:@escaping(Bool)->Void) {
        var request=URLRequest(url:address.appendingPathComponent("api/health"),cachePolicy:.reloadIgnoringLocalCacheData)
        request.timeoutInterval=1
        URLSession.shared.dataTask(with:request){ data,response,error in
            let info=data.flatMap{try? JSONSerialization.jsonObject(with:$0) as? [String:Any]}
            let healthy=(response as? HTTPURLResponse)?.statusCode==200 && info?["app"] as? String=="Match Downloader"
            DispatchQueue.main.async{callback(healthy)}
        }.resume()
    }

    func begin() {
        health { healthy in
            if healthy {self.openLibrary();return}
            self.startBackend()
        }
    }
    func startBackend() {
        let python=root.appendingPathComponent(".venv/bin/python")
        let script=root.appendingPathComponent("app.py")
        guard FileManager.default.isExecutableFile(atPath:python.path),FileManager.default.fileExists(atPath:script.path) else {
            showStatus("Match Downloader setup is missing",detail:"Keep Match Downloader.app in its folder beside app.py and .venv. See README.md for setup on another laptop.");return
        }
        do {
            let library=root.appendingPathComponent("library",isDirectory:true)
            try FileManager.default.createDirectory(at:library,withIntermediateDirectories:true)
            let log=library.appendingPathComponent("desktop.log")
            if !FileManager.default.fileExists(atPath:log.path) {FileManager.default.createFile(atPath:log.path,contents:nil)}
            let output=try FileHandle(forWritingTo:log);try output.seekToEnd()
            let process=Process()
            process.executableURL=python
            process.arguments=[script.path,"--no-browser"]
            process.currentDirectoryURL=root
            var env=ProcessInfo.processInfo.environment
            env["PATH"]="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            env["PYTHONUNBUFFERED"]="1"
            process.environment=env
            process.standardOutput=output;process.standardError=output;process.standardInput=FileHandle.nullDevice
            process.terminationHandler={ _ in DispatchQueue.main.async {
                if !self.quitting {
                    self.timer?.invalidate()
                    self.showStatus("Match Downloader stopped",detail:"Quit and reopen Match Downloader to restart. If another copy of the app is open, quit it first. Details are saved in library/desktop.log.")
                }
            }}
            backend=process;try process.run()
            attempts=0
            timer=Timer.scheduledTimer(withTimeInterval:0.5,repeats:true){ _ in
                if self.checking{return}
                self.checking=true;self.attempts+=1
                self.health { healthy in
                    self.checking=false
                    if healthy {self.openLibrary()}
                    else if self.attempts>=60 {self.timer?.invalidate();self.showStatus("Match Downloader could not start",detail:"Quit and reopen the app. Check library/desktop.log if this continues.")}
                }
            }
        } catch {showStatus("Match Downloader could not start",detail:error.localizedDescription)}
    }
    func openLibrary() {
        timer?.invalidate();timer=nil
        window.contentView=browser
        browser.load(URLRequest(url:address))
    }
    func webView(_ webView:WKWebView, decidePolicyFor navigationAction:WKNavigationAction, decisionHandler:@escaping(WKNavigationActionPolicy)->Void) {
        decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
    }
    func webView(_ webView:WKWebView, navigationAction:WKNavigationAction, didBecome download:WKDownload) {download.delegate=self}
    func download(_ download:WKDownload, decideDestinationUsing response:URLResponse, suggestedFilename:String, completionHandler:@escaping(URL?)->Void) {
        let panel=NSSavePanel();panel.nameFieldStringValue=suggestedFilename
        panel.beginSheetModal(for:window){ result in completionHandler(result == .OK ? panel.url : nil) }
    }
    func webView(_ webView:WKWebView, createWebViewWith configuration:WKWebViewConfiguration, for navigationAction:WKNavigationAction, windowFeatures:WKWindowFeatures)->WKWebView? {
        if let url=navigationAction.request.url {NSWorkspace.shared.open(url)}
        return nil
    }
}
let app=NSApplication.shared
app.setActivationPolicy(.regular)
let delegate=MatchDownloaderDesktop()
app.delegate=delegate
app.run()
