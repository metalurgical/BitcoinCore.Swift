import BigInt
import Foundation
import HdWalletKit
import HsToolKit

public class BitcoinCore {
    private let storage: IStorage
    private var dataProvider: IDataProvider
    private let publicKeyManager: IPublicKeyManager
    private let watchedTransactionManager: IWatchedTransactionManager
    private let addressConverter: AddressConverterChain
    private let restoreKeyConverterChain: RestoreKeyConverterChain
    private let unspentOutputSelector: UnspentOutputSelectorChain

    private let transactionCreator: ITransactionCreator?
    private let transactionFeeCalculator: ITransactionFeeCalculator?
    private let dustCalculator: IDustCalculator?
    private let paymentAddressParser: IPaymentAddressParser

    private let networkMessageSerializer: NetworkMessageSerializer
    private let networkMessageParser: NetworkMessageParser

    private let syncManager: SyncManager
    private let pluginManager: IPluginManager

    private let purpose: Purpose
    private let peerManager: IPeerManager

    // START: Extending

    public let peerGroup: IPeerGroup
    public let initialDownload: IInitialDownload
    public let transactionSyncer: ITransactionSyncer

    let bloomFilterLoader: BloomFilterLoader
    let inventoryItemsHandlerChain = InventoryItemsHandlerChain()
    let peerTaskHandlerChain = PeerTaskHandlerChain()

    public func add(inventoryItemsHandler: IInventoryItemsHandler) {
        inventoryItemsHandlerChain.add(handler: inventoryItemsHandler)
    }

    public func add(peerTaskHandler: IPeerTaskHandler) {
        peerTaskHandlerChain.add(handler: peerTaskHandler)
    }

    public func add(restoreKeyConverter: IRestoreKeyConverter) {
        restoreKeyConverterChain.add(converter: restoreKeyConverter)
    }

    @discardableResult public func add(messageParser: IMessageParser) -> Self {
        networkMessageParser.add(parser: messageParser)
        return self
    }

    @discardableResult public func add(messageSerializer: IMessageSerializer) -> Self {
        networkMessageSerializer.add(serializer: messageSerializer)
        return self
    }

    public func add(plugin: IPlugin) {
        pluginManager.add(plugin: plugin)
    }

    func publicKey(byPath path: String) throws -> PublicKey {
        try publicKeyManager.publicKey(byPath: path)
    }

    public func prepend(addressConverter: IAddressConverter) {
        self.addressConverter.prepend(addressConverter: addressConverter)
    }

    public func prepend(unspentOutputSelector: IUnspentOutputSelector) {
        self.unspentOutputSelector.prepend(unspentOutputSelector: unspentOutputSelector)
    }

    // END: Extending

    public var delegateQueue = DispatchQueue(label: "io.horizontalsystems.bitcoin-core.bitcoin-core-delegate-queue")
    public weak var delegate: BitcoinCoreDelegate?

    init(storage: IStorage, dataProvider: IDataProvider,
         peerGroup: IPeerGroup, initialDownload: IInitialDownload, bloomFilterLoader: BloomFilterLoader, transactionSyncer: ITransactionSyncer,
         publicKeyManager: IPublicKeyManager, addressConverter: AddressConverterChain, restoreKeyConverterChain: RestoreKeyConverterChain,
         unspentOutputSelector: UnspentOutputSelectorChain,
         transactionCreator: ITransactionCreator?, transactionFeeCalculator: ITransactionFeeCalculator?, dustCalculator: IDustCalculator?,
         paymentAddressParser: IPaymentAddressParser, networkMessageParser: NetworkMessageParser, networkMessageSerializer: NetworkMessageSerializer,
         syncManager: SyncManager, pluginManager: IPluginManager, watchedTransactionManager: IWatchedTransactionManager, purpose: Purpose,
         peerManager: IPeerManager)
    {
        self.storage = storage
        self.dataProvider = dataProvider
        self.peerGroup = peerGroup
        self.initialDownload = initialDownload
        self.bloomFilterLoader = bloomFilterLoader
        self.transactionSyncer = transactionSyncer
        self.publicKeyManager = publicKeyManager
        self.addressConverter = addressConverter
        self.restoreKeyConverterChain = restoreKeyConverterChain
        self.unspentOutputSelector = unspentOutputSelector
        self.transactionCreator = transactionCreator
        self.transactionFeeCalculator = transactionFeeCalculator
        self.dustCalculator = dustCalculator
        self.paymentAddressParser = paymentAddressParser

        self.networkMessageParser = networkMessageParser
        self.networkMessageSerializer = networkMessageSerializer

        self.syncManager = syncManager
        self.pluginManager = pluginManager
        self.watchedTransactionManager = watchedTransactionManager

        self.purpose = purpose
        self.peerManager = peerManager
    }
}

extension BitcoinCore {
    public func start() {
        syncManager.start()
    }

    func stop() {
        syncManager.stop()
    }
}

public extension BitcoinCore {
    var watchAccount: Bool { // TODO: What is better way to determine watch?
        transactionCreator == nil
    }

    var lastBlockInfo: BlockInfo? {
        dataProvider.lastBlockInfo
    }

    var balance: BalanceInfo {
        dataProvider.balance
    }

    var syncState: BitcoinCore.KitState {
        syncManager.syncState
    }

    func transactions(fromUid: String? = nil, type: TransactionFilterType?, limit: Int? = nil) -> [TransactionInfo] {
        dataProvider.transactions(fromUid: fromUid, type: type, limit: limit)
    }

    func transaction(hash: String) -> TransactionInfo? {
        dataProvider.transaction(hash: hash)
    }

    var unspentOutputs: [UnspentOutput] {
        unspentOutputSelector.all
    }

    var unspentOutputsInfo: [UnspentOutputInfo] {
        unspentOutputSelector.all.map {
            .init(
                outputIndex: $0.output.index,
                transactionHash: $0.output.transactionHash,
                timestamp: TimeInterval($0.transaction.timestamp),
                address: $0.output.address,
                value: $0.output.value
            )
        }
    }

    func send(to address: String, memo: String?, value: Int, feeRate: Int, sortType: TransactionDataSortType, unspentOutputs: [UnspentOutputInfo]?, pluginData: [UInt8: IPluginData] = [:]) throws -> FullTransaction {
        guard let transactionCreator else {
            throw CoreError.readOnlyCore
        }

        let outputs = unspentOutputs.map { $0.outputs(from: unspentOutputSelector.all) }
        return try transactionCreator.create(to: address, memo: memo, value: value, feeRate: feeRate, senderPay: true, sortType: sortType, unspentOutputs: outputs, pluginData: pluginData)
    }

    func send(to address: String, memo: String?, value: Int, feeRate: Int, sortType: TransactionDataSortType, pluginData: [UInt8: IPluginData]) throws -> FullTransaction {
        try send(to: address, memo: memo, value: value, feeRate: feeRate, sortType: sortType, unspentOutputs: nil, pluginData: pluginData)
    }

    func send(to hash: Data, memo: String?, scriptType: ScriptType, value: Int, feeRate: Int, sortType: TransactionDataSortType, unspentOutputs: [UnspentOutputInfo]?) throws -> FullTransaction {
        guard let transactionCreator else {
            throw CoreError.readOnlyCore
        }

        let outputs = unspentOutputs.map { $0.outputs(from: unspentOutputSelector.all) }
        let toAddress = try addressConverter.convert(lockingScriptPayload: hash, type: scriptType)
        return try transactionCreator.create(to: toAddress.stringValue, memo: memo, value: value, feeRate: feeRate, senderPay: true, sortType: sortType, unspentOutputs: outputs, pluginData: [:])
    }

    internal func redeem(from unspentOutput: UnspentOutput, memo: String?, to address: String, feeRate: Int, sortType: TransactionDataSortType) throws -> FullTransaction {
        guard let transactionCreator else {
            throw CoreError.readOnlyCore
        }

        return try transactionCreator.create(from: unspentOutput, to: address, memo: memo, feeRate: feeRate, sortType: sortType)
    }

    func createRawTransaction(to address: String, memo: String?, value: Int, feeRate: Int, sortType: TransactionDataSortType, unspentOutputs: [UnspentOutput]?, pluginData: [UInt8: IPluginData] = [:]) throws -> Data {
        guard let transactionCreator else {
            throw CoreError.readOnlyCore
        }

        return try transactionCreator.createRawTransaction(to: address, memo: memo, value: value, feeRate: feeRate, senderPay: true, sortType: sortType, unspentOutputs: unspentOutputs, pluginData: pluginData)
    }

    func validate(address: String, pluginData: [UInt8: IPluginData] = [:]) throws {
        try pluginManager.validate(address: addressConverter.convert(address: address), pluginData: pluginData)
    }

    func parse(paymentAddress: String) -> BitcoinPaymentData {
        paymentAddressParser.parse(paymentAddress: paymentAddress)
    }

    func sendInfo(for value: Int, toAddress: String? = nil, memo: String?, feeRate: Int, unspentOutputs: [UnspentOutput]?, pluginData: [UInt8: IPluginData] = [:]) throws -> BitcoinSendInfo {
        guard let transactionFeeCalculator else {
            throw CoreError.readOnlyCore
        }

        return try transactionFeeCalculator.sendInfo(for: value, feeRate: feeRate, senderPay: true, toAddress: toAddress, memo: memo, unspentOutputs: unspentOutputs, pluginData: pluginData)
    }

    func maxSpendableValue(toAddress: String? = nil, memo: String?, feeRate: Int, unspentOutputs: [UnspentOutputInfo]?, pluginData: [UInt8: IPluginData] = [:]) throws -> Int {
        guard let transactionFeeCalculator else {
            throw CoreError.readOnlyCore
        }

        let outputs = unspentOutputs.map { $0.outputs(from: unspentOutputSelector.all) }
        let balance = outputs.map { $0.map(\.output.value).reduce(0, +) } ?? balance.spendable

        let sendAllFee = try transactionFeeCalculator.sendInfo(for: balance, feeRate: feeRate, senderPay: false, toAddress: toAddress, memo: memo, unspentOutputs: outputs, pluginData: pluginData).fee
        return max(0, balance - sendAllFee)
    }

    func minSpendableValue(toAddress: String? = nil) throws -> Int {
        guard let dustCalculator else {
            throw CoreError.readOnlyCore
        }

        var scriptType = ScriptType.p2pkh
        if let addressStr = toAddress, let address = try? addressConverter.convert(address: addressStr) {
            scriptType = address.scriptType
        }

        return dustCalculator.dust(type: scriptType)
    }

    func maxSpendLimit(pluginData: [UInt8: IPluginData]) throws -> Int? {
        try pluginManager.maxSpendLimit(pluginData: pluginData)
    }

    func receiveAddress() -> String {
        guard let publicKey = try? publicKeyManager.receivePublicKey(),
              let address = try? addressConverter.convert(publicKey: publicKey, type: purpose.scriptType)
        else {
            return ""
        }

        return address.stringValue
    }

    func changePublicKey() throws -> PublicKey {
        try publicKeyManager.changePublicKey()
    }

    func receivePublicKey() throws -> PublicKey {
        try publicKeyManager.receivePublicKey()
    }

    func usedAddresses(change: Bool) -> [UsedAddress] {
        publicKeyManager.usedPublicKeys(change: change).compactMap { pubKey in
            let address = try? addressConverter.convert(publicKey: pubKey, type: purpose.scriptType)
            return address.map { UsedAddress(index: pubKey.index, address: $0.stringValue) }
        }
    }

    internal func watch(transaction: BitcoinCore.TransactionFilter, delegate: IWatchedTransactionDelegate) {
        watchedTransactionManager.add(transactionFilter: transaction, delegatedTo: delegate)
    }

    func debugInfo(network: INetwork) -> String {
        dataProvider.debugInfo(network: network, scriptType: purpose.scriptType, addressConverter: addressConverter)
    }

    var statusInfo: [(String, Any)] {
        var status = [(String, Any)]()
        status.append(("state", syncManager.syncState.toString()))
        status.append(("synced until", ((lastBlockInfo?.timestamp.map { Double($0) })?.map { Date(timeIntervalSince1970: $0) }) ?? "n/a"))
        status.append(("syncing peer", initialDownload.syncPeer?.host ?? "n/a"))
        status.append(("derivation", purpose.description))

        status.append(contentsOf:
            peerManager.connected.enumerated().map { index, peer in
                var peerStatus = [(String, Any)]()
                peerStatus.append(("status", initialDownload.isSynced(peer: peer) ? "synced" : "not synced"))
                peerStatus.append(("host", peer.host))
                peerStatus.append(("best block", peer.announcedLastBlockHeight))
                peerStatus.append(("user agent", peer.announcedLastBlockHeight))

                let tasks = peer.tasks
                if tasks.isEmpty {
                    peerStatus.append(("tasks", "no tasks"))
                } else {
                    peerStatus.append(("tasks", tasks.map { task in
                        (String(describing: task), task.state)
                    }))
                }

                return ("peer \(index + 1)", peerStatus)
            }
        )

        return status
    }

    internal func rawTransaction(transactionHash: String) -> String? {
        dataProvider.rawTransaction(transactionHash: transactionHash)
    }
}

extension BitcoinCore: IDataProviderDelegate {
    func transactionsUpdated(inserted: [TransactionInfo], updated: [TransactionInfo]) {
        delegateQueue.async { [weak self] in
            if let kit = self {
                kit.delegate?.transactionsUpdated(inserted: inserted, updated: updated)
            }
        }
    }

    func transactionsDeleted(hashes: [String]) {
        delegateQueue.async { [weak self] in
            self?.delegate?.transactionsDeleted(hashes: hashes)
        }
    }

    func balanceUpdated(balance: BalanceInfo) {
        delegateQueue.async { [weak self] in
            if let kit = self {
                kit.delegate?.balanceUpdated(balance: balance)
            }
        }
    }

    func lastBlockInfoUpdated(lastBlockInfo: BlockInfo) {
        delegateQueue.async { [weak self] in
            if let kit = self {
                kit.delegate?.lastBlockInfoUpdated(lastBlockInfo: lastBlockInfo)
            }
        }
    }
}

extension BitcoinCore: ISyncManagerDelegate {
    func kitStateUpdated(state: KitState) {
        delegateQueue.async { [weak self] in
            self?.delegate?.kitStateUpdated(state: state)
        }
    }
}

public protocol BitcoinCoreDelegate: AnyObject {
    func transactionsUpdated(inserted: [TransactionInfo], updated: [TransactionInfo])
    func transactionsDeleted(hashes: [String])
    func balanceUpdated(balance: BalanceInfo)
    func lastBlockInfoUpdated(lastBlockInfo: BlockInfo)
    func kitStateUpdated(state: BitcoinCore.KitState)
}

public extension BitcoinCoreDelegate {
    func transactionsUpdated(inserted _: [TransactionInfo], updated _: [TransactionInfo]) {}
    func transactionsDeleted(hashes _: [String]) {}
    func balanceUpdated(balance _: BalanceInfo) {}
    func lastBlockInfoUpdated(lastBlockInfo _: BlockInfo) {}
    func kitStateUpdated(state _: BitcoinCore.KitState) {}
}

public extension BitcoinCore {
    enum KitState {
        case synced
        case apiSyncing(transactions: Int)
        case syncing(progress: Double)
        case notSynced(error: Error)

        func toString() -> String {
            switch self {
            case .synced: return "Synced"
            case let .apiSyncing(transactions): return "ApiSyncing-\(transactions)"
            case let .syncing(progress): return "Syncing-\(Int(progress * 100))"
            case let .notSynced(error): return "NotSynced-\(String(reflecting: error))"
            }
        }
    }

    enum SyncMode: Equatable {
        case blockchair(key: String) // Restore and sync from Blockchair API.
        case api // Restore and sync from API.
        case full // Sync from bip44Checkpoint. Api restore disabled
    }

    enum TransactionFilter {
        case p2shOutput(scriptHash: Data)
        case outpoint(transactionHash: Data, outputIndex: Int)
    }
}

extension BitcoinCore.KitState: Equatable {
    public static func == (lhs: BitcoinCore.KitState, rhs: BitcoinCore.KitState) -> Bool {
        switch (lhs, rhs) {
        case (.synced, .synced):
            return true
        case let (.apiSyncing(transactions: leftCount), .apiSyncing(transactions: rightCount)):
            return leftCount == rightCount
        case let (.syncing(progress: leftProgress), .syncing(progress: rightProgress)):
            return leftProgress == rightProgress
        case let (.notSynced(lhsError), .notSynced(rhsError)):
            return "\(lhsError)" == "\(rhsError)"
        default:
            return false
        }
    }
}

public extension BitcoinCore {
    enum CoreError: Error {
        case readOnlyCore
    }

    enum StateError: Error {
        case notStarted
    }
}
