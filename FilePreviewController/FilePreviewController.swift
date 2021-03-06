//
//  FilePreviewController.swift
//  FilePreviewController
//
//  Created by WangWei on 16/2/22.
//  Copyright © 2016年 Teambition. All rights reserved.
//

import Foundation
import QuickLook
import Alamofire
import UIKit
fileprivate func < <T : Comparable>(lhs: T?, rhs: T?) -> Bool {
  switch (lhs, rhs) {
  case let (l?, r?):
    return l < r
  case (nil, _?):
    return true
  default:
    return false
  }
}

fileprivate func > <T : Comparable>(lhs: T?, rhs: T?) -> Bool {
  switch (lhs, rhs) {
  case let (l?, r?):
    return l > r
  default:
    return rhs < lhs
  }
}


public struct FilePreviewControllerConstants {
   public static let filePathComponent = "com.teambition.RemoteQuickLook"
}

public extension String {
    public func MD5() -> String {
        return (self as NSString).md5() as String
    }
    
    public func stringByAppendingPathComponent(_ str: String) -> String {
        return (self as NSString).appendingPathComponent(str)
    }
    
    public func stringByAppendingPathExtension(_ str: String) -> String? {
        return (self as NSString).appendingPathExtension(str)
    }
}

public func localFilePathFor(_ URL: Foundation.URL, fileName: String? = nil, fileExtension: String? = nil) -> String? {
    var url = URL
    if let fileExtension = fileExtension, url.pathExtension.characters.count == 0 {
        url = url.appendingPathExtension(fileExtension)
    }
    var saveName: String?
    if let fileName = fileName?.replacingOccurrences(of: "/", with: ":"), let fileExtension = fileExtension {
        saveName = fileName
        if fileName.components(separatedBy: ".").count == 1 {
            saveName = "\(fileName).\(fileExtension)"
        }
    }
    
    var URLString = URL.absoluteString
    if let query = URL.query {
        URLString = URL.absoluteString.replacingOccurrences(of: query, with: "")
    }
    let hashedURL = URLString.MD5()

    guard var cacheDirectory = NSSearchPathForDirectoriesInDomains(FileManager.SearchPathDirectory.cachesDirectory, FileManager.SearchPathDomainMask.userDomainMask, true).last else {
        return nil
    }
    cacheDirectory = cacheDirectory.stringByAppendingPathComponent(FilePreviewControllerConstants.filePathComponent)
    cacheDirectory = cacheDirectory.stringByAppendingPathComponent(hashedURL)
    var isDirectory: ObjCBool = false
    if !FileManager.default.fileExists(atPath: cacheDirectory, isDirectory: &isDirectory) || !isDirectory.boolValue {
        do {
            try FileManager.default.createDirectory(atPath: cacheDirectory, withIntermediateDirectories: true, attributes: nil)
        } catch _{
            return nil
        }
    }
    let lastPathComponent = saveName ?? url.lastPathComponent
    if lastPathComponent.characters.count > 0 {
        // add extra directory to keep original file name when share
        cacheDirectory = cacheDirectory.stringByAppendingPathComponent(lastPathComponent)
    }

    return cacheDirectory
}

open class FilePreviewItem: NSObject, QLPreviewItem {
    open var previewItemURL: URL?
    open var previewItemTitle: String?
    
    /// when fileExtension is nil, will try to get pathExtension from previewItemURL
    open var fileExtension: String?
    
    public init(previewItemURL: URL?, previewItemTitle: String? = nil, fileExtension: String? = nil) {
        self.previewItemURL = previewItemURL
        self.previewItemTitle = previewItemTitle
        self.fileExtension = fileExtension
        super.init()
    }
}

private var myContext = 0

open class FilePreviewController: QLPreviewController {
    
    /// if header is not nil, Alamofire will use it for authentication
    open var headers: [String: String]?
    open var enableShare = true
    open var actionItems = [FPActionBarItem]() {
        willSet {
            for item in newValue {
                item.filePreviewController = self
            }
        }
        didSet {
            toolbarItems = actionItems.map { $0.barButtonItem }
        }
    }
    override open var toolbarItems: [UIBarButtonItem]? {
        didSet {
            items = toolbarItems
        }
    }
    open var items: [UIBarButtonItem]?
    fileprivate lazy var bottomProgressView: UIProgressView = {
        let progressView = UIProgressView(progressViewStyle: .bar)
        progressView.frame = CGRect(x: 0, y: 0, width: self.view.frame.width, height: 2)
        progressView.autoresizingMask = [.flexibleWidth, .flexibleBottomMargin]
        progressView.tintColor = UIColor.blue
        return progressView
    }()
    fileprivate var shouldDisplayToolbar: Bool {
        get {
            return items?.count > 0
        }
    }

    lazy var navigationBar: UINavigationBar? = {
        var bar: UINavigationBar?
        if let navigationBar = self.navigationController?.navigationBar {
            bar = navigationBar
        } else {
            let nBar = self.getNavigationBar(fromView: self.view)
            bar = nBar
        }

        if let navigationBar = bar {
            if !self.isObserving {
                navigationBar.addObserver(self, forKeyPath: "center", options: [.new, .old], context: &myContext)
                self.isObserving = true
            }
        }
        return bar
    }()

    lazy var originalToolbar: UIToolbar? = {
        var bar: UIToolbar?
        if let subviews = self.navigationBar?.superview?.subviews {
            for view in subviews {
                if let toolbar = view as? UIToolbar {
                    bar = toolbar
                    break
                }
            }
        }
        bar?.tintColor = UIColor.white
        return bar
    }()
    var customNavigationBar: UINavigationBar?
    lazy var leftBarButtonItem: UIBarButtonItem = {
        let crossImage = UIImage(named: "icon-cross", in: Bundle.init(for: FilePreviewController.self), compatibleWith: nil)
        return UIBarButtonItem(image: crossImage, style: .plain, target: self, action: #selector(dismissSelf))
    }()
    lazy var rightBarButtonItem: UIBarButtonItem = {
        let shareImage = UIImage(named: "icon-share", in: Bundle.init(for: FilePreviewController.self), compatibleWith: nil)
        let item = UIBarButtonItem(image: shareImage, style: .plain, target: self, action: #selector(showShareActivity))
        item.isEnabled = false
        return item
    }()
    var isObserving = false
    var isFullScreen = false
    
    var originalDataSource: QLPreviewControllerDataSource?
    
    var progress: CGFloat = 0
    var progressBar: UIProgressView?
    var toolbar: UIToolbar?
    
    var toolbarBottomConstraint: NSLayoutConstraint?
    
    open weak var controllerDelegate: FilePreviewControllerDelegate?
    
    var interactionController: UIDocumentInteractionController?

    override open func viewDidLoad() {
        super.viewDidLoad()
        let crossImage = UIImage(named: "icon-cross", in: Bundle.init(for: FilePreviewController.self), compatibleWith: nil)
        navigationItem.leftBarButtonItem = UIBarButtonItem(image: crossImage, style: .plain, target: self, action: #selector(dismissSelf))
    }
    
    override open func viewDidLayoutSubviews() {
        layoutToolbar()
    }

    override open func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if let navigationBar = navigationBar, let container = navigationBar.superview {
            let bar = UINavigationBar(frame: CGRect(x: 0, y: 0, width: view.frame.width, height: 64))
            bar.autoresizingMask = [.flexibleWidth]
            container.addSubview(bar)
            let item = UINavigationItem(title: navigationItem.title ?? "")
            item.leftBarButtonItem = leftBarButtonItem
            if enableShare {
                item.rightBarButtonItem = rightBarButtonItem
            }
            item.hidesBackButton = true
            bar.pushItem(item, animated: true)
            customNavigationBar = bar
        }
    }
    
    deinit {
        if let navigationBar = navigationBar {
            navigationBar.removeObserver(self, forKeyPath: "center")
        }
    }
    
    override open func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        cancelProgress()
        customNavigationBar?.removeFromSuperview()
    }
    
    override open func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if context == &myContext, let keyPath = keyPath , keyPath == "center", let object = object as? UINavigationBar , object == navigationBar {
            if let change = change {
                if let new = change[NSKeyValueChangeKey.newKey] as? NSValue {
                    let point = new.cgPointValue
                    if !isFullScreen && point.y < 0 {
                        toolbarBottomConstraint?.constant = -44
                        isFullScreen = true
                        UIView.animate(withDuration: 0.2, animations: {
                            self.view.layoutIfNeeded()
                            self.customNavigationBar?.frame.origin.y = -64
                            self.navigationBar?.superview?.layoutIfNeeded()
                            }, completion: { (_) in
                                self.originalToolbar?.isHidden = true
                                self.navigationBar?.superview?.sendSubview(toBack: self.navigationBar!)
                        })
                    } else if isFullScreen && point.y > 0 {
                        toolbarBottomConstraint?.constant = shouldDisplayToolbar ? 0 : -45
                        isFullScreen = false
                        UIView.animate(withDuration: 0.2, animations: {
                            self.view.layoutIfNeeded()
                            self.customNavigationBar?.frame.origin.y = 0
                            self.navigationBar?.superview?.layoutIfNeeded()
                            self.originalToolbar?.isHidden = true
                            self.navigationBar?.superview?.bringSubview(toFront: self.customNavigationBar!)
                            }, completion: { (_) in
                                self.navigationBar?.superview?.bringSubview(toFront: self.customNavigationBar!)
                                self.originalToolbar?.isHidden = true
                        })
                    }
                    setNeedsStatusBarAppearanceUpdate()
                }
            }
        }
    }

    override open var prefersStatusBarHidden : Bool {
        return isFullScreen
    }
    
    func dismissSelf() {
        presentingViewController?.dismissFilePreviewController()
    }

    func getNavigationBar(fromView view: UIView) -> UINavigationBar? {
        for v in view.subviews {
            if v is UINavigationBar {
                return v as? UINavigationBar
            } else {
                if let bar = getNavigationBar(fromView: v) {
                    return bar
                }
            }
        }
        return nil
    }
}

// MARK: - Share
public extension FilePreviewController {
    func showShareActivity() {
        guard let previewItem = currentPreviewItem as? FilePreviewItem else {
            return
        }
        if let delegate = controllerDelegate {
            delegate.previewController(self, willShareItem: previewItem)
        } else {
            showDefautlShareActivity()
        }
    }

    public func showDefautlShareActivity() {
        if let previewItemURL = currentPreviewItem?.previewItemURL {
            interactionController = UIDocumentInteractionController(url: previewItemURL)
            interactionController?.presentOptionsMenu(from: rightBarButtonItem, animated: true)
        }
    }
}

public extension FilePreviewController {
    func beginUpdate() {
        if bottomProgressView.superview == nil {
            toolbar?.addSubview(bottomProgressView)
        }
    }
    func endUpdate() {
        bottomProgressView.removeFromSuperview()
    }
    func update(progress value: Float) {
        bottomProgressView.progress = value
    }
}

extension FilePreviewController {
    func downloadFor(_ item: FilePreviewItem) {
        
        UIApplication.shared.isNetworkActivityIndicatorVisible = true
        guard let previewItemUrl = item.previewItemURL, let localFilePath = localFilePathFor(previewItemUrl, fileName: item.previewItemTitle, fileExtension: item.fileExtension) else {
            if let controllerDelegate = self.controllerDelegate {
                let error = FPError.errorWithCode(.localCacheDirectoryCreateFailed, failureReason: "Create cache directory failed")
                controllerDelegate.previewController(self, failedToLoadRemotePreviewItem: item, error: error)
            }
            return
        }
        let destination: DownloadRequest.DownloadFileDestination = { _, _ in
            return (URL(fileURLWithPath: localFilePath), [.createIntermediateDirectories, .removePreviousFile])
        }
        download(previewItemUrl.absoluteString, method: .get, parameters: nil, encoding: JSONEncoding.default, headers: headers, to: destination).downloadProgress(queue: DispatchQueue.main) { (progress) in
            var progress = CGFloat(progress.completedUnitCount) / CGFloat(progress.totalUnitCount)
            if progress < 0 {
                progress = 0.5
            }
            self.updateProgress(progress)
        }
        .response { response in
            UIApplication.shared.isNetworkActivityIndicatorVisible = false
            self.cancelProgress()
            if let error = response.error {
                if let controllerDelegate = self.controllerDelegate {
                    let rasieError = FPError.errorWithCode(.remoteFileDownloadFailed, failureReason: "Download remote file failed", error: error)
                    controllerDelegate.previewController(self, failedToLoadRemotePreviewItem: item, error: rasieError)
                }
            } else {
                self.refreshCurrentPreviewItem()
            }
        }
    }
    
    func updateProgress(_ newProgress: CGFloat) {
        if progressBar == nil {
            progressBar = UIProgressView(progressViewStyle: .bar)
            progressBar?.progress = 0.1
            layoutProgressBar()
        }
        guard let progressBar = progressBar else {
            return
        }
        if progress == 1.0 {
            cancelProgress()
        }
        progress = newProgress
        progressBar.progress = Float(newProgress)
    }
    
    func cancelProgress() {
        guard let progressBar = progressBar else {
            return
        }
        UIView.animate(withDuration: 0.5, animations: { () -> Void in
            progressBar.alpha = 0
            }, completion: { (_) -> Void in
                progressBar.removeFromSuperview()
        })
    }
    
    func layoutProgressBar() {
        guard let navigationBar = customNavigationBar, let progressBar = progressBar else {
            return
        }
        if !navigationBar.subviews.contains(progressBar) {
            progressBar.tintColor = navigationBar.tintColor
            navigationBar.addSubview(progressBar)
        }
        let navigationBarHeight = navigationBar.frame.height
        let navigationBarWidth = navigationBar.frame.width
        let progressBarHeight = progressBar.frame.height
        progressBar.frame = CGRect(x: 0, y: navigationBarHeight - progressBarHeight, width: navigationBarWidth, height: progressBarHeight)
    }
    
    func layoutToolbar() {
        originalToolbar?.isHidden = true
        if toolbar == nil {
            toolbar = UIToolbar()
            if let toolbar = toolbar {
                view.addSubview(toolbar)
                toolbar.translatesAutoresizingMaskIntoConstraints = false
                view.addConstraints(NSLayoutConstraint.constraints(withVisualFormat: "H:|-0-[toolbar]-0-|", options: [], metrics: nil , views: ["toolbar":toolbar]))
                toolbar.addConstraint(NSLayoutConstraint(item: toolbar, attribute: .height, relatedBy: .equal, toItem: nil, attribute: .notAnAttribute, multiplier: 1.0, constant: 44))
                toolbarBottomConstraint = NSLayoutConstraint(item: view, attribute: .bottom, relatedBy: .equal, toItem: toolbar, attribute: .bottom, multiplier: 1.0, constant: 0)
                view.addConstraint(toolbarBottomConstraint!)
            }

            guard let toolbar = toolbar, let items = items , items.count > 0 else {
                toolbarBottomConstraint?.constant = -44
                return
            }
            let flexSpace = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: self, action: nil)
            let fixedSpace = UIBarButtonItem(barButtonSystemItem: .fixedSpace, target: self, action: nil)
            fixedSpace.width = 72
            
            var itemsArray = [UIBarButtonItem]()
            if UIDevice.current.userInterfaceIdiom == .pad {
                itemsArray.append(flexSpace)
                for item in items {
                    itemsArray.append(item)
                    itemsArray.append(fixedSpace)
                }
                itemsArray.removeLast()
                itemsArray.append(flexSpace)
            } else {
                if items.count == 1, let first = items.first {
                    itemsArray = [flexSpace, first, flexSpace]
                } else if items.count == 2, let first = items.first, let last = items.last {
                    itemsArray = [flexSpace, first, flexSpace, flexSpace, last, flexSpace]
                } else {
                    for item in items {
                        itemsArray.append(item)
                        itemsArray.append(flexSpace)
                    }
                    if itemsArray.count > 0 {
                        itemsArray.removeLast()
                    }
                }
            }
            
            toolbar.setItems(itemsArray, animated: false)
            toolbar.tintColor = UIColor.white
        }
        if let toolbar = toolbar {
            view.bringSubview(toFront: toolbar)
        }
    }
    
    open override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { (_) -> Void in
            self.layoutProgressBar()
            }, completion: nil)
    }
}

extension FilePreviewController: QLPreviewControllerDataSource {
    
    //This method is required to expose, don't call it
    public func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        guard let originalDataSource = originalDataSource else {
            return 0
        }
        return originalDataSource.numberOfPreviewItems(in: controller)
    }
    
    //This method is required to expose, don't call it
    public func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        
        let originalPreviewItem = (originalDataSource!.previewController(controller, previewItemAt: index)) as! FilePreviewItem
        
        guard let previewItemURL = originalPreviewItem.previewItemURL else {
            return originalPreviewItem
        }
        if previewItemURL.isFileURL {
            rightBarButtonItem.isEnabled = true
            return originalPreviewItem
        }
        
        //If it's a remote file, check cache
        
        var copyItem: FilePreviewItem!
        if let itemTitle = originalPreviewItem.previewItemTitle {
            copyItem = FilePreviewItem(previewItemURL: originalPreviewItem.previewItemURL, previewItemTitle: itemTitle)
        } else {
            copyItem = FilePreviewItem(previewItemURL: originalPreviewItem.previewItemURL)
        }
        
        guard let localFilePath = localFilePathFor(previewItemURL, fileName: originalPreviewItem.previewItemTitle, fileExtension: originalPreviewItem.fileExtension) else {
            //failed to get local file path
            if let controllerDelegate = self.controllerDelegate {
                let error = FPError.errorWithCode(.localCacheDirectoryCreateFailed, failureReason: "Create cache directory failed")
                controllerDelegate.previewController(self, failedToLoadRemotePreviewItem: originalPreviewItem, error: error)
            }
            return originalPreviewItem
        }
        copyItem.previewItemURL = URL(fileURLWithPath: localFilePath)
        
        if FileManager.default.fileExists(atPath: localFilePath) {
            rightBarButtonItem.isEnabled = true
            return copyItem
        } else {
            //Download remote file if cache not exist
            downloadFor(originalPreviewItem)
        }
        copyItem.previewItemURL = nil
        return copyItem
    }
}
