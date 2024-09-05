//
//  FileBrowserViewController.swift
//
//  CotEditor
//  https://coteditor.com
//
//  Created by 1024jp on 2024-05-01.
//
//  ---------------------------------------------------------------------------
//
//  © 2024 1024jp
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  https://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import AppKit
import Combine
import AudioToolbox
import Defaults
import ControlUI
import URLUtils

/// Column identifiers for outline view.
private extension NSUserInterfaceItemIdentifier {
    
    static let node = NSUserInterfaceItemIdentifier("node")
}


final class FileBrowserViewController: NSViewController, NSMenuItemValidation {
    
    private enum SerializationKey {
        
        static let expandedItems = "expandedItems"
    }
    
    
    let document: DirectoryDocument
    
    @ViewLoading private var outlineView: NSOutlineView
    @ViewLoading private var addButton: NSPopUpButton
    
    private var defaultObservers: Set<AnyCancellable> = []
    private var treeObservationTask: Task<Void, Never>?
    
    
    // MARK: Lifecycle
    
    init(document: DirectoryDocument) {
        
        self.document = document
        
        super.init(nibName: nil, bundle: nil)
        
        // set identifier for state restoration
        self.identifier = NSUserInterfaceItemIdentifier("FileBrowserViewController")
        
        document.fileBrowserViewController = self
    }
    
    
    required init?(coder: NSCoder) {
        
        fatalError("init(coder:) has not been implemented")
    }
    
    
    override func loadView() {
        
        let outlineView = NSOutlineView()
        outlineView.headerView = nil
        outlineView.addTableColumn(NSTableColumn())
        
        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        
        let addButton = NSPopUpButton()
        (addButton.cell as! NSPopUpButtonCell).arrowPosition = .noArrow
        addButton.pullsDown = true
        addButton.isBordered = false
        addButton.addItem(withTitle: "")
        addButton.item(at: 0)!.image = NSImage(systemSymbolName: "plus", accessibilityDescription: String(localized: "Add", table: "Document"))
        
        self.view = NSVisualEffectView()
        self.view.addSubview(scrollView)
        self.view.addSubview(addButton)
        
        self.outlineView = outlineView
        self.addButton = addButton
        
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: self.view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            addButton.topAnchor.constraint(equalToSystemSpacingBelow: scrollView.bottomAnchor, multiplier: 1),
            addButton.bottomAnchor.constraint(equalTo: self.view.bottomAnchor, constant: -6),
            addButton.leadingAnchor.constraint(equalTo: self.view.leadingAnchor, constant: 6),
        ])
    }
    
    
    override func viewDidLoad() {
        
        super.viewDidLoad()
        
        self.outlineView.dataSource = self
        self.outlineView.delegate = self
        
        self.outlineView.registerForDraggedTypes([.fileURL])
        self.outlineView.setDraggingSourceOperationMask([.copy, .delete], forLocal: false)
        
        let contextMenu = NSMenu()
        contextMenu.items = [
            NSMenuItem(title: String(localized: "Show in Finder", table: "Document", comment: "menu item label"),
                       action: #selector(showInFinder), keyEquivalent: ""),
            .separator(),
            
            NSMenuItem(title: String(localized: "Open in New Window", table: "Document", comment: "menu item label"),
                       action: #selector(openInNewWindow), keyEquivalent: ""),
            NSMenuItem(title: String(localized: "Open with External Editor", table: "Document", comment: "menu item label"),
                       action: #selector(openWithExternalEditor), keyEquivalent: ""),
            .separator(),
            
            NSMenuItem(title: String(localized: "Move to Trash", table: "Document", comment: "menu item label"),
                       action: #selector(moveToTrash), keyEquivalent: ""),
            NSMenuItem(title: String(localized: "Duplicate", table: "Document", comment: "menu item label"),
                       action: #selector(duplicate), keyEquivalent: ""),
            .separator(),
            
            NSMenuItem(title: String(localized: "New File", table: "Document", comment: "menu item label"),
                       action: #selector(addFile), keyEquivalent: ""),
            NSMenuItem(title: String(localized: "New Folder", table: "Document", comment: "menu item label"),
                       action: #selector(addFolder), keyEquivalent: ""),
            .separator(),
            
            NSMenuItem(title: String(localized: "Share…", table: "Document", comment: "menu item label"),
                       action: #selector(share), keyEquivalent: ""),
            .separator(),
            
            NSMenuItem(title: String(localized: "Show Hidden Files", table: "Document", comment: "menu item label"),
                       action: #selector(toggleHiddenFileVisibility), keyEquivalent: ""),
        ]
        self.outlineView.menu = contextMenu
        
        self.addButton.menu!.items += [
            NSMenuItem(title: String(localized: "New File", table: "Document", comment: "menu item label"),
                       action: #selector(addFile), keyEquivalent: ""),
            NSMenuItem(title: String(localized: "New Folder", table: "Document", comment: "menu item label"),
                       action: #selector(addFolder), keyEquivalent: ""),
        ]
    }
    
    
    override func viewWillAppear() {
        
        super.viewWillAppear()
        
        self.outlineView.reloadData()
        
        self.treeObservationTask = Task {
            for await _ in NotificationCenter.default.notifications(named: DirectoryDocument.didUpdateFileNodeNotification, object: self.document).map(\.name) {
                let selectedNodes = self.outlineView.selectedRowIndexes.compactMap(self.outlineView.item(atRow:))
                self.outlineView.reloadData()
                let indexes = selectedNodes.compactMap(self.outlineView.row(forItem:))
                    .reduce(into: IndexSet()) { $0.insert($1) }
                if !indexes.isEmpty {
                    self.outlineView.selectRowIndexes(indexes, byExtendingSelection: false)
                }
            }
        }
        
        self.defaultObservers = [
            UserDefaults.standard.publisher(for: .fileBrowserShowsHiddenFiles)
                .sink { [unowned self] _ in self.outlineView.reloadData() },
        ]
    }
    
    
    override func viewDidDisappear() {
        
        super.viewDidDisappear()
        
        self.treeObservationTask?.cancel()
        self.treeObservationTask = nil
        
        self.defaultObservers.removeAll()
    }
    
    
    override func encodeRestorableState(with coder: NSCoder) {
        
        super.encodeRestorableState(with: coder)
        
        // store expanded items
        if let rootURL = self.document.fileURL {
            let paths = (0..<self.outlineView.numberOfRows)
                .compactMap { self.outlineView.item(atRow: $0) }
                .filter { self.outlineView.isItemExpanded($0) }
                .compactMap { $0 as? FileNode }
                .map { $0.fileURL.path(relativeTo: rootURL) }
            
            if !paths.isEmpty {
                coder.encode(paths, forKey: SerializationKey.expandedItems)
            }
        }
    }
    
    
    override func restoreState(with coder: NSCoder) {
        
        super.restoreState(with: coder)
        
        // restore expanded items
        if let rootURL = self.document.fileURL,
           let paths = coder.decodeArrayOfObjects(ofClass: NSString.self, forKey: SerializationKey.expandedItems) as? [String]
        {
            let nodes = paths
                .map { URL(filePath: $0, relativeTo: rootURL) }
                .compactMap { self.document.fileNode?.node(at: $0) }
            
            for node in nodes {
                self.outlineView.expandItem(node)
            }
        }
    }
    
    
    // MARK: Public Methods
    
    /// Selects the current document in the outline view.
    func selectCurrentDocument() {
        
        guard
            let fileURL = self.document.currentDocument?.fileURL,
            let node = self.document.fileNode?.node(at: fileURL)
        else { return }
        
        self.select(node: node)
    }
    
    
    // MARK: Actions
    
    override func responds(to aSelector: Selector!) -> Bool {
        
        switch aSelector {
            case #selector(copy(_:)):
                MainActor.assumeIsolated {
                    !self.outlineView.selectedRowIndexes.isEmpty
                }
            default:
                super.responds(to: aSelector)
        }
    }
    
    
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        
        switch menuItem.action {
            case #selector(copy(_:)):
                return self.targetNode(for: menuItem) != nil
                
            case #selector(showInFinder):
                menuItem.isHidden = self.clickedNode == nil
                
            case #selector(openWithExternalEditor):
                menuItem.isHidden = self.clickedNode?.isFolder != false
                
            case #selector(openInNewWindow):
                menuItem.isHidden = self.clickedNode == nil
                
            case #selector(addFile):
                return self.targetFolderNode(for: menuItem)?.isWritable != false
                
            case #selector(addFolder):
                return self.targetFolderNode(for: menuItem)?.isWritable != false
                
            case #selector(duplicate):
                menuItem.isHidden = self.clickedNode == nil
                
            case #selector(moveToTrash):
                menuItem.isHidden = self.clickedNode == nil
                return self.clickedNode?.isWritable == true
                
            case #selector(share):
                menuItem.isHidden = self.clickedNode == nil
                
            case #selector(toggleHiddenFileVisibility):
                menuItem.state = self.showsHiddenFiles ? .on : .off
                
            case nil:
                return false
                
            default:
                break
        }
        
        return true
    }
    
    
    @IBAction func copy(_ sender: Any?) {
        
        guard let node = self.targetNode(for: sender) else { return }
        
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([node.fileURL as NSURL])
    }
    
    
    @IBAction func showInFinder(_ sender: Any?) {
        
        guard let node = self.clickedNode else { return }
        
        NSWorkspace.shared.activateFileViewerSelecting([node.fileURL])
    }
    
    
    @IBAction func openWithExternalEditor(_ sender: Any?) {
        
        guard let node = self.clickedNode else { return }
        
        NSWorkspace.shared.open(node.fileURL)
    }
    
    
    @IBAction func openInNewWindow(_ sender: Any?) {
        
        guard let node = self.clickedNode else { return }
        
        self.openInWindow(at: node)
    }
    
    
    @IBAction func addFile(_ sender: NSMenuItem) {
        
        guard let folderNode = self.targetFolderNode(for: sender) else { return }
        
        let node: FileNode
        do {
            node = try self.document.addFile(at: folderNode)
        } catch {
            return self.presentErrorAsSheet(error)
        }
        
        // update UI
        if let index = self.children(of: folderNode)?.firstIndex(of: node) {
            let parent = (folderNode == self.document.fileNode) ? nil : folderNode
            self.outlineView.insertItems(at: [index], inParent: parent, withAnimation: .slideDown)
        }
        self.select(node: node, edit: true)
    }
    
    
    @IBAction func addFolder(_ sender: NSMenuItem) {
        
        guard let folderNode = self.targetFolderNode(for: sender) else { return }
        
        let node: FileNode
        do {
            node = try self.document.addFolder(at: folderNode)
        } catch {
            return self.presentErrorAsSheet(error)
        }
        
        // update UI
        if let index = self.children(of: folderNode)?.firstIndex(of: node) {
            let parent = (folderNode == self.document.fileNode) ? nil : folderNode
            self.outlineView.insertItems(at: [index], inParent: parent, withAnimation: .slideDown)
        }
        self.select(node: node, edit: true)
    }
    
    
    @IBAction func duplicate(_ sender: Any?) {
        
        guard let node = self.clickedNode else { return }
        
        let newNode: FileNode
        do {
            newNode = try self.document.duplicateItem(at: node)
        } catch {
            return self.presentErrorAsSheet(error)
        }
        
        // update UI
        if let index = self.children(of: newNode.parent)?.firstIndex(of: newNode) {
            let parent = (newNode.parent == self.document.fileNode) ? nil : newNode.parent
            self.outlineView.insertItems(at: [index], inParent: parent, withAnimation: .slideDown)
        }
        self.select(node: newNode)
    }
    
    
    @IBAction func moveToTrash(_ sender: Any?) {
        
        guard let node = self.clickedNode else { return }
        
        self.trashNodes([node])
    }
    
    
    @IBAction func share(_ menuItem: NSMenuItem) {
        
        guard
            let node = self.clickedNode,
            let view = self.outlineView.rowView(atRow: self.outlineView.clickedRow, makeIfNecessary: false)
        else { return }
        
        let picker = NSSharingServicePicker(items: [node.fileURL])
        picker.show(relativeTo: .zero, of: view, preferredEdge: .minX)
    }
    
    
    @IBAction func toggleHiddenFileVisibility(_ sender: Any?) {
        
        self.showsHiddenFiles.toggle()
    }
    
    
    // MARK: Private Methods
    
    /// Whether displaying hidden files.
    private var showsHiddenFiles: Bool {
        
        get { UserDefaults.standard[.fileBrowserShowsHiddenFiles] }
        set { UserDefaults.standard[.fileBrowserShowsHiddenFiles] = newValue }
    }
    
    
    /// The outline item currently clicked.
    private var clickedNode: FileNode? {
        
        self.outlineView.item(atRow: self.outlineView.clickedRow) as? FileNode
    }
    
    
    /// Returns the target file node for the menu action.
    ///
    /// - Parameter menuItem: The sender of the action.
    /// - Returns: A file node.
    private func targetNode(for sender: Any?) -> FileNode? {
        
        let isContextMenu = ((sender as? NSMenuItem)?.menu == self.outlineView.menu)
        let row = isContextMenu ? self.outlineView.clickedRow : self.outlineView.selectedRow
        
        return self.outlineView.item(atRow: row) as? FileNode ?? self.document.fileNode
    }
    
    
    /// Returns the folder node to perform action of the menu item.
    ///
    /// - Parameter menuItem: The sender of the action.
    /// - Returns: A file node.
    private func targetFolderNode(for sender: NSMenuItem) -> FileNode? {
        
        guard let targetNode = self.targetNode(for: sender) else { return nil }
        
        return targetNode.isDirectory ? targetNode : targetNode.parent
    }
    
    
    /// Selects the specified item in the outline view.
    ///
    /// - Parameters:
    ///   - node: The note item to select.
    ///   - edit: If `true`, the text field will be in the editing mode.
    private func select(node: FileNode, edit: Bool = false) {
        
        node.parents.reversed().forEach { self.outlineView.expandItem($0) }
        
        let row = self.outlineView.row(forItem: node)
        
        guard row >= 0 else { return assertionFailure() }
        
        self.outlineView.selectRowIndexes([row], byExtendingSelection: false)
        
        if edit {
            self.outlineView.editColumn(0, row: row, with: nil, select: false)
        }
    }
    
    
    /// Open in a separate window by resolving any file link.
    ///
    /// - Parameter node: The file node to open.
    private func openInWindow(at node: FileNode) {
        
        let fileURL: URL
        do {
            fileURL = try node.resolvedFileURL
        } catch {
            self.presentError(error)
            return
        }
        
        self.document.openInWindow(fileURL: fileURL)
    }
    
    
    /// Moves the given nodes to the Trash.
    ///
    /// - Parameter nodes: The file nodes to move to the Trash.
    private func trashNodes(_ nodes: [FileNode]) {
        
        guard !nodes.isEmpty else { return }
        
        self.outlineView.beginUpdates()
        for node in nodes {
            do {
                try self.document.trashItem(node)
            } catch {
                self.presentErrorAsSheet(error)
                continue
            }
            
            let parent = self.outlineView.parent(forItem: node)
            let index = self.outlineView.childIndex(forItem: node)
            
            guard index >= 0 else { continue }
            
            self.outlineView.removeItems(at: [index], inParent: parent, withAnimation: .slideUp)
        }
        self.outlineView.endUpdates()
        AudioServicesPlaySystemSound(.moveToTrash)
    }
}


// MARK: Outline View Data Source

extension FileBrowserViewController: NSOutlineViewDataSource {
    
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        
        self.children(of: item)?.count ?? 0
    }
    
    
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        
        (item as! FileNode).isDirectory
    }
    
    
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        
        self.children(of: item)![index]
    }
    
    
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        
        (item as? FileNode)?.fileURL as? NSURL
    }
    
    
    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        
        guard
            index == NSOutlineViewDropOnItemIndex,
            let fileURLs = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
            let rootNode = self.document.fileNode
        else { return [] }
        
        var destNode = item as? FileNode ?? rootNode
        
        if !destNode.isDirectory {  // avoid dropping on a leaf
            let parent = outlineView.parent(forItem: item)
            outlineView.setDropItem(parent, dropChildIndex: NSOutlineViewDropOnItemIndex)
            destNode = parent as? FileNode ?? rootNode
        }
        
        guard destNode.isWritable else { return [] }
        
        guard !fileURLs.contains(destNode.fileURL) else { return [] }
        
        let isLocal = info.draggingSource as? NSOutlineView == outlineView
        
        // cannot drop to descendants
        if isLocal {
            info.numberOfValidItemsForDrop = fileURLs.count { !$0.isAncestor(of: destNode.fileURL) }
        }
        
        guard info.numberOfValidItemsForDrop > 0 else { return [] }
        
        return isLocal ? .move : .copy
    }
    
    
    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        
        guard
            let fileURLs = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
            let destNode = item as? FileNode ?? self.document.fileNode
        else { return false }
        
        let isLocal = info.draggingSource as? NSOutlineView == outlineView
        var didMove = false
        
        self.outlineView.beginUpdates()
        for fileURL in fileURLs {
            if isLocal {
                guard
                    let node = self.document.fileNode?.node(at: fileURL),
                    node.parent != destNode  // ignore same location
                else { continue }
                
                do {
                    try self.document.moveItem(at: node, to: destNode)
                } catch {
                    self.presentErrorAsSheet(error)
                    continue
                }
                
                let oldIndex = self.outlineView.childIndex(forItem: node)
                let oldParent = self.outlineView.parent(forItem: node)
                let childIndex = self.children(of: destNode)?.firstIndex(of: node)
                self.outlineView.moveItem(at: oldIndex, inParent: oldParent, to: childIndex ?? 0, inParent: item)
                
            } else {
                let node: FileNode
                do {
                    node = try self.document.copyItem(at: fileURL, to: destNode)
                } catch {
                    self.presentErrorAsSheet(error)
                    continue
                }
                
                let childIndex = self.children(of: destNode)?.firstIndex(of: node)
                self.outlineView.insertItems(at: [childIndex ?? 0], inParent: item, withAnimation: .slideDown)
            }
            
            didMove = true
        }
        self.outlineView.endUpdates()
        
        return didMove
    }
    
    
    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        
        switch operation {
            case .delete:  // ended at the Trash
                guard let fileURLs = session.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else { return }
                
                let nodes = fileURLs.compactMap { self.document.fileNode?.node(at: $0) }
                self.trashNodes(nodes)
                
            default:
                break
        }
    }
    
    
    /// Returns the casted children of the given item provided by an API of `NSOutlineViewDataSource`.
    ///
    /// - Parameter item: An item in the data source, or `nil` for the root.
    /// - Returns: An array of file nodes, or `nil` if no data source is provided yet.
    private func children(of item: Any?) -> [FileNode]? {
        
        (item as? FileNode ?? self.document.fileNode)?.children?
            .filter { self.showsHiddenFiles || !$0.isHidden }
    }
}


// MARK: Outline View Delegate

extension FileBrowserViewController: NSOutlineViewDelegate {
    
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        
        let node = item as! FileNode
        let cellView = outlineView.makeView(withIdentifier: .node, owner: self) as? FileBrowserTableCellView ?? .init()
        cellView.textField?.delegate = self
        
        cellView.imageView!.image = node.kind.image
        cellView.imageView!.alphaValue = node.isHidden ? 0.5 : 1
        cellView.isAlias = node.isAlias
        
        cellView.textField!.stringValue = node.name
        cellView.textField!.textColor = node.isHidden ? .disabledControlTextColor : .labelColor
        
        return cellView
    }
    
    
    func outlineViewSelectionDidChange(_ notification: Notification) {
        
        let outlineView = notification.object as! NSOutlineView
        
        guard
            self.outlineView.numberOfSelectedRows == 1,
            let node = outlineView.item(atRow: outlineView.selectedRow) as? FileNode,
            !node.isDirectory,
            !node.isAlias
        else { return }
        
        Task {
            await self.document.openDocument(at: node.fileURL)
        }
    }
    
    
    func outlineViewItemDidExpand(_ notification: Notification) {
        
        self.invalidateRestorableState()
    }
    
    
    func outlineViewItemDidCollapse(_ notification: Notification) {
        
        self.invalidateRestorableState()
    }
}


// MARK: Text Field Delegate

extension FileBrowserViewController: NSTextFieldDelegate {
    
    func control(_ control: NSControl, textShouldBeginEditing fieldEditor: NSText) -> Bool {
        
        let row = self.outlineView.row(for: control)
        
        guard let node = self.outlineView.item(atRow: row) as? FileNode else { return false }
        
        // avoid renaming unsaved document
        guard self.document.openedDocument(at: node)?.isDocumentEdited != true else { return false }
        
        return node.isWritable
    }
    
    
    func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
        
        let row = self.outlineView.row(for: control)
        
        guard let node = self.outlineView.item(atRow: row) as? FileNode else { return false }
        
        if fieldEditor.string == node.name { return true }  // not changed
        
        do {
            try self.document.renameItem(at: node, with: fieldEditor.string)
        } catch {
            fieldEditor.string = node.name
            self.presentErrorAsSheet(error)
            return false
        }
        
        return true
    }
}


// MARK: -

final class FileBrowserTableCellView: NSTableCellView {
    
    var isAlias: Bool = false { didSet { self.aliasArrowView?.isHidden = !isAlias } }
    
    private var aliasArrowView: NSImageView?
    
    
    override init(frame frameRect: NSRect) {
        
        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.alignment = .center
        
        let textField = FilenameTextField()
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.drawsBackground = false
        textField.isBordered = false
        textField.lineBreakMode = .byTruncatingMiddle
        textField.isEditable = true
        
        let aliasArrowView = NSImageView()
        aliasArrowView.translatesAutoresizingMaskIntoConstraints = false
        aliasArrowView.alignment = .center
        aliasArrowView.image = .arrowAliasFill
        aliasArrowView.symbolConfiguration = .init(paletteColors: [.labelColor, .controlBackgroundColor])
        aliasArrowView.setAccessibilityHidden(true)
        
        super.init(frame: frameRect)
        
        self.identifier = .node
        self.addSubview(textField)
        self.addSubview(imageView)
        self.addSubview(aliasArrowView)
        self.textField = textField
        self.imageView = imageView
        self.aliasArrowView = aliasArrowView
        
        NSLayoutConstraint.activate([
            imageView.firstBaselineAnchor.constraint(equalTo: textField.firstBaselineAnchor),
            aliasArrowView.firstBaselineAnchor.constraint(equalTo: textField.firstBaselineAnchor),
            textField.centerYAnchor.constraint(equalTo: self.centerYAnchor),
            imageView.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 2),
            imageView.widthAnchor.constraint(equalToConstant: 17),  // the value used in a sample code by Apple
            aliasArrowView.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
            textField.leadingAnchor.constraint(equalToSystemSpacingAfter: imageView.trailingAnchor, multiplier: 1),
            textField.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -2),
        ])
    }
    
    
    required init?(coder: NSCoder) {
        
        fatalError("init(coder:) has not been implemented")
    }
}


// MARK: - Extensions

private extension FileNode.Kind {
    
    /// The symbol image in `NSImage`.
    var image: NSImage {
        
        NSImage(systemSymbolName: self.symbolName, accessibilityDescription: self.label)!
    }
}
