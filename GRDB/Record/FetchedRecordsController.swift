//
//  FetchedRecordsController.swift
//  GRDB
//
//  Created by Pascal Edmond on 09/12/2015.
//  Copyright © 2015 Gwendal Roué. All rights reserved.
//
import UIKit

/// You use a FetchedRecordsController to feed a UITableView with the results
/// returned from an SQLite request.
///
/// It looks and behaves very much like Core Data's NSFetchedResultsController.
///
/// Given a fetch request, and a type that adopts the RowConvertible protocol,
/// such as a subclass of the Record class, a FetchedRecordsController is able
/// to return the results of the request in a form that is suitable for a
/// UITableView, with one table view row per fetched record.
///
/// FetchedRecordsController can also monitor the results of the fetch request,
/// and notify its delegate of any change. Those changes can be easily turned
/// into animated table view deletions, insertions, updates and moves.
///
/// # Creating the Fetched Records Controller
///
/// You typically create an instance of FetchedRecordsController as a property
/// of a table view controller. When you initialize the fetch records
/// controller, you provide the following information:
///
/// - The type of the fetched records. It must be a type that adopts the
///   RowConvertible protocol, such as a subclass of the Record class.
///
/// - A fetch request. It can be a raw SQL query with its arguments, or a
///   FetchRequest from the GRDB Query Interface.
///
/// - Optionally, a way to tell if two records have the same identity. Without
///   this identity comparison, all record updates are seen as replacements,
///   and your table view updates are less smooth.
///
/// After creating an instance, you invoke `performFetch()` to actually execute
/// the fetch.
///
///     class Person : Record { ... }
///
///     let dbQueue = DatabaseQueue(...)
///     let request = Person.order(SQLColumn("name"))
///     let controller: FetchedRecordsController<Person> = FetchedRecordsController(
///         dbQueue,
///         request,
///         compareRecordsByPrimaryKey: true)
///     controller.performFetch()
///
/// In the example above, two persons are considered identical if they share
/// the same primary key, thanks to the `compareRecordsByPrimaryKey` argument.
/// This initializer argument is only available for types such as
/// Record subclasses that adopt the RowConvertible protocol, and also the
/// Persistable or MutablePersistable protocols.
///
/// If your type only adopts RowConvertible, you need to be more explicit, and
/// provide your own identity comparison function:
///
///     struct Person : RowConvertible {
///         let id: Int64
///         ...
///     }
///
///     let controller: FetchedRecordsController<Person> = FetchedRecordsController(
///         dbQueue,
///         request,
///         isSameRecord: { $0.id == $1.id })
///
/// Instead of a FetchRequest object, you can also provide a raw SQL query:
///
///     let controller: FetchedRecordsController<Person> = FetchedRecordsController(
///         dbQueue,
///         "SELECT * FROM persons ORDER BY name",
///         compareRecordsByPrimaryKey: true)
///
/// The fetch request can involve several database tables:
///
///     let controller: FetchedRecordsController<Person> = FetchedRecordsController(
///         dbQueue,
///         "SELECT persons.*, COUNT(books.id) AS bookCount " +
///         "FROM persons " +
///         "LEFT JOIN books ON books.owner_id = persons.id " +
///         "GROUP BY persons.id " +
///         "ORDER BY persons.name",
///         compareRecordsByPrimaryKey: true)
///
/// # The Controllers's Delegate
///
/// Any change in the database that affects the record set is processed and the
/// records are updated accordingly. The controller notifies the delegate when
/// records change location (see FetchedRecordsControllerDelegate). You
/// typically use these methods to update the display of the table view.
///
///
/// # Implementing the Table View Datasource Methods
///
/// The table view data source asks the fetched records controller to provide
/// relevant information:
///
///     func numberOfSectionsInTableView(tableView: UITableView) -> Int {
///         return fetchedRecordsController.sections.count
///     }
///
///     func tableView(tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
///         return fetchedRecordsController.sections[section].numberOfRecords
///     }
///
///     func tableView(tableView: UITableView, cellForRowAtIndexPath indexPath: NSIndexPath) -> UITableViewCell {
///         let cell = /* Get the cell */
///         let record = fetchedRecordsController.recordAtIndexPath(indexPath)
///         /* Configure the cell */
///         return cell
///     }
///
///
/// # Responding to Changes
///
/// In general, FetchedRecordsController is designed to respond to changes at
/// the database layer, by informing its delegate when database rows change
/// location or values.
///
/// Changes are not reflected until they are applied in the database by a
/// successful transaction. Transactions can be explicit, or implicit:
///
///     try dbQueue.inTransaction { db in
///         /* Change a person's attributes */
///         try person.save(db)
///         return .Commit      // Explicit transaction
///     }
///
///     try dbQueue.inDatavase { db in
///         /* Change a person's attributes */
///         try person.save(db) // Implicit transaction
///     }
///
/// When you apply several changes to the database, you should group them in a
/// single transaction. The controller will then notify its delegate of all
/// changes together.
///
public final class FetchedRecordsController<Record: RowConvertible> {
    
    // MARK: - Initialization
    
    // TODO: document that queue MUST be serial
    public convenience init(_ database: DatabaseWriter, _ sql: String, arguments: StatementArguments? = nil, queue: dispatch_queue_t = dispatch_get_main_queue(), isSameRecord: ((Record, Record) -> Bool)? = nil) {
        let source: DatabaseSource<Record> = .SQL(sql, arguments)
        self.init(database: database, source: source, queue: queue, isSameRecord: isSameRecord)
    }
    
    // TODO: document that queue MUST be serial
    public convenience init<T>(_ database: DatabaseWriter, _ request: FetchRequest<T>, queue: dispatch_queue_t = dispatch_get_main_queue(), isSameRecord: ((Record, Record) -> Bool)? = nil) {
        let request: FetchRequest<Record> = FetchRequest(query: request.query) // Retype the fetch request
        let source = DatabaseSource.FetchRequest(request)
        self.init(database: database, source: source, queue: queue, isSameRecord: isSameRecord)
    }
    
    private convenience init(database: DatabaseWriter, source: DatabaseSource<Record>, queue: dispatch_queue_t, isSameRecord: ((Record, Record) -> Bool)?) {
        if let isSameRecord = isSameRecord {
            self.init(database: database, source: source, queue: queue, isSameRecordBuilder: { _ in isSameRecord })
        } else {
            self.init(database: database, source: source, queue: queue, isSameRecordBuilder: { _ in { _ in false } })
        }
    }
    
    private init(database: DatabaseWriter, source: DatabaseSource<Record>, queue: dispatch_queue_t, isSameRecordBuilder: (Database) -> (Record, Record) -> Bool) {
        self.source = source
        self.database = database
        self.isSameRecordBuilder = isSameRecordBuilder
        self.diffQueue = dispatch_queue_create("GRDB.FetchedRecordsController.diff", DISPATCH_QUEUE_SERIAL)
        self.mainQueue = queue
        database.addTransactionObserver(self)
    }
    
    /// MUST BE CALLED ON mainQueue (TODO: say it nicely)
    public func performFetch() {
        // Use database.write, so that we are serialized with transaction
        // callbacks, which happen on the writing queue.
        database.write { db in
            let statement = try! self.source.selectStatement(db)
            self.mainItems = Item<Record>.fetchAll(statement)
            if !self.isObserving {
                self.isSameRecord = self.isSameRecordBuilder(db)
                self.diffItems = self.mainItems
                self.observedTables = statement.sourceTables
                
                // OK now we can start observing
                db.addTransactionObserver(self)
                self.isObserving = true
            }
        }
    }
    
    
    
    // MARK: - Configuration
    
    public weak var delegate: FetchedRecordsControllerDelegate?
    
    
    // Configuration: database
    
    /// The databaseWriter
    public let database: DatabaseWriter
    
    
    // MARK: - Accessing records
    
    /// Returns the records of the query.
    /// Returns nil if performQuery() hasn't been called.
    ///
    /// MUST BE CALLED ON mainQueue (TODO: say it nicely)
    public var fetchedRecords: [Record]? {
        if isObserving {
            return mainItems.map { $0.record }
        }
        return nil
    }
    
    
    /// Returns the fetched record at a given indexPath.
    ///
    /// MUST BE CALLED ON mainQueue (TODO: say it nicely)
    public func recordAtIndexPath(indexPath: NSIndexPath) -> Record {
        return mainItems[indexPath.indexAtPosition(1)].record
    }
    
    /// Returns the indexPath of a given record.
    ///
    /// MUST BE CALLED ON mainQueue (TODO: say it nicely)
    public func indexPathForRecord(record: Record) -> NSIndexPath? {
        if let index = mainItems.indexOf({ isSameRecord($0.record, record) }) {
            return NSIndexPath(forRow: index, inSection: 0)
        }
        return nil
    }
    
    
    // MARK: - Querying Sections Information
    
    /// The sections
    ///
    /// MUST BE CALLED ON mainQueue (TODO: say it nicely)
    public var sections: [FetchedRecordsSectionInfo<Record>] {
        // We only support a single section
        return [FetchedRecordsSectionInfo(controller: self)]
    }
    
    
    // MARK: - Not public
    
    
    // mainQueue protected data exposed in public API
    private var mainQueue: dispatch_queue_t
    
    // Set to true in performFetch()
    private var isObserving: Bool = false           // protected by mainQueue
    
    // The items exposed on public API
    private var mainItems: [Item<Record>] = []      // protected by mainQueue
    
    // The record comparator. When the Record type adopts MutablePersistable, we
    // need to wait for performFetch() in order to build it, because
    private var isSameRecord: ((Record, Record) -> Bool) = { _ in false }
    private let isSameRecordBuilder: (Database) -> (Record, Record) -> Bool
    
    
    /// The source
    private let source: DatabaseSource<Record>
    
    /// The observed tables. Set in performFetch()
    private var observedTables: Set<String> = []    // protected by database queue
    
    /// True if databaseDidCommit(db) should compute changes
    private var needsComputeChanges = false         // protected by database queue
    
    
    
    // Configuration: records
    
    
    private var diffItems: [Item<Record>] = []      // protected by diffQueue
    private var diffQueue: dispatch_queue_t

    private func computeChanges(fromRows s: [Item<Record>], toRows t: [Item<Record>]) -> [ItemChange<Record>] {
        
        let m = s.count
        let n = t.count
        
        // Fill first row and column of insertions and deletions.
        
        var d: [[[ItemChange<Record>]]] = Array(count: m + 1, repeatedValue: Array(count: n + 1, repeatedValue: []))
        
        var changes = [ItemChange<Record>]()
        for (row, item) in s.enumerate() {
            let deletion = ItemChange.Deletion(item: item, indexPath: NSIndexPath(forRow: row, inSection: 0))
            changes.append(deletion)
            d[row + 1][0] = changes
        }
        
        changes.removeAll()
        for (col, item) in t.enumerate() {
            let insertion = ItemChange.Insertion(item: item, indexPath: NSIndexPath(forRow: col, inSection: 0))
            changes.append(insertion)
            d[0][col + 1] = changes
        }
        
        if m == 0 || n == 0 {
            // Pure deletions or insertions
            return d[m][n]
        }
        
        // Fill body of matrix.
        for tx in 0..<n {
            for sx in 0..<m {
                if s[sx] == t[tx] {
                    d[sx+1][tx+1] = d[sx][tx] // no operation
                } else {
                    var del = d[sx][tx+1]     // a deletion
                    var ins = d[sx+1][tx]     // an insertion
                    var sub = d[sx][tx]       // a substitution
                    
                    // Record operation.
                    let minimumCount = min(del.count, ins.count, sub.count)
                    if del.count == minimumCount {
                        let deletion = ItemChange.Deletion(item: s[sx], indexPath: NSIndexPath(forRow: sx, inSection: 0))
                        del.append(deletion)
                        d[sx+1][tx+1] = del
                    } else if ins.count == minimumCount {
                        let insertion = ItemChange.Insertion(item: t[tx], indexPath: NSIndexPath(forRow: tx, inSection: 0))
                        ins.append(insertion)
                        d[sx+1][tx+1] = ins
                    } else {
                        let deletion = ItemChange.Deletion(item: s[sx], indexPath: NSIndexPath(forRow: sx, inSection: 0))
                        let insertion = ItemChange.Insertion(item: t[tx], indexPath: NSIndexPath(forRow: tx, inSection: 0))
                        sub.append(deletion)
                        sub.append(insertion)
                        d[sx+1][tx+1] = sub
                    }
                }
            }
        }
        
        /// Returns an array where deletion/insertion pairs of the same element are replaced by `.Move` change.
        func standardizeChanges(changes: [ItemChange<Record>]) -> [ItemChange<Record>] {
            
            /// Returns a potential .Move or .Update if *change* has a matching change in *changes*:
            /// If *change* is a deletion or an insertion, and there is a matching inverse
            /// insertion/deletion with the same value in *changes*, a corresponding .Move or .Update is returned.
            /// As a convenience, the index of the matched change is returned as well.
            func mergedChange(change: ItemChange<Record>, inChanges changes: [ItemChange<Record>]) -> (mergedChange: ItemChange<Record>, mergedIndex: Int)? {
                
                /// Returns the changes between two rows: a dictionary [key: oldValue]
                /// Precondition: both rows have the same columns
                func changedValues(from oldRow: Row, to newRow: Row) -> [String: DatabaseValue] {
                    var changedValues: [String: DatabaseValue] = [:]
                    for (column, newValue) in newRow {
                        let oldValue = oldRow[column]!
                        if newValue != oldValue {
                            changedValues[column] = oldValue
                        }
                    }
                    return changedValues
                }
                
                switch change {
                case .Insertion(let newItem, let newIndexPath):
                    // Look for a matching deletion
                    for (index, otherChange) in changes.enumerate() {
                        guard case .Deletion(let oldItem, let oldIndexPath) = otherChange else { continue }
                        guard isSameRecord(oldItem.record, newItem.record) else { continue }
                        let rowChanges = changedValues(from: oldItem.row, to: newItem.row)
                        if oldIndexPath == newIndexPath {
                            return (ItemChange.Update(item: newItem, indexPath: oldIndexPath, changes: rowChanges), index)
                        } else {
                            return (ItemChange.Move(item: newItem, indexPath: oldIndexPath, newIndexPath: newIndexPath, changes: rowChanges), index)
                        }
                    }
                    return nil
                    
                case .Deletion(let oldItem, let oldIndexPath):
                    // Look for a matching insertion
                    for (index, otherChange) in changes.enumerate() {
                        guard case .Insertion(let newItem, let newIndexPath) = otherChange else { continue }
                        guard isSameRecord(oldItem.record, newItem.record) else { continue }
                        let rowChanges = changedValues(from: oldItem.row, to: newItem.row)
                        if oldIndexPath == newIndexPath {
                            return (ItemChange.Update(item: newItem, indexPath: oldIndexPath, changes: rowChanges), index)
                        } else {
                            return (ItemChange.Move(item: newItem, indexPath: oldIndexPath, newIndexPath: newIndexPath, changes: rowChanges), index)
                        }
                    }
                    return nil
                    
                default:
                    return nil
                }
            }
            
            // Updates must be pushed at the end
            var mergedChanges: [ItemChange<Record>] = []
            var updateChanges: [ItemChange<Record>] = []
            for change in changes {
                if let (mergedChange, mergedIndex) = mergedChange(change, inChanges: mergedChanges) {
                    mergedChanges.removeAtIndex(mergedIndex)
                    switch mergedChange {
                    case .Update:
                        updateChanges.append(mergedChange)
                    default:
                        mergedChanges.append(mergedChange)
                    }
                } else {
                    mergedChanges.append(change)
                }
            }
            return mergedChanges + updateChanges
        }
        
        return standardizeChanges(d[m][n])
    }
}

extension FetchedRecordsController where Record: MutablePersistable {
    
    // TODO: document that queue MUST be serial
    public convenience init(_ database: DatabaseWriter, _ sql: String, arguments: StatementArguments? = nil, queue: dispatch_queue_t = dispatch_get_main_queue(), compareRecordsByPrimaryKey: Bool) {
        let source: DatabaseSource<Record> = .SQL(sql, arguments)
        if compareRecordsByPrimaryKey {
            self.init(database: database, source: source, queue: queue, isSameRecordBuilder: { db in try! Record.primaryKeyComparator(db) })
        } else {
            self.init(database: database, source: source, queue: queue, isSameRecordBuilder: { _ in { _ in false } })
        }
    }
    
    // TODO: document that queue MUST be serial
    public convenience init<U>(_ database: DatabaseWriter, _ request: FetchRequest<U>, queue: dispatch_queue_t = dispatch_get_main_queue(), compareRecordsByPrimaryKey: Bool) {
        let request: FetchRequest<Record> = FetchRequest(query: request.query) // Retype the fetch request
        let source = DatabaseSource.FetchRequest(request)
        if compareRecordsByPrimaryKey {
            self.init(database: database, source: source, queue: queue, isSameRecordBuilder: { db in try! Record.primaryKeyComparator(db) })
        } else {
            self.init(database: database, source: source, queue: queue, isSameRecordBuilder: { _ in { _ in false } })
        }
    }
}


// MARK: - <TransactionObserverType>

extension FetchedRecordsController : TransactionObserverType {
    
    public func databaseDidChangeWithEvent(event: DatabaseEvent) {
        if observedTables.contains(event.tableName) {
            needsComputeChanges = true
        }
    }
    
    public func databaseWillCommit() throws { }
    
    public func databaseDidRollback(db: Database) {
        needsComputeChanges = false
    }
    
    public func databaseDidCommit(db: Database) {
        // The databaseDidCommit callback is called in a serialized dispatch
        // queue: It is guaranteed to process the last database transaction.
        
        guard needsComputeChanges else {
            return
        }
        needsComputeChanges = false
        
        let statement = try! source.selectStatement(db)
        let newItems = Item<Record>.fetchAll(statement)
        
        dispatch_async(diffQueue) { [weak self] in
            // This code, submitted to the serial diffQueue, is guaranteed
            // to process the last database transaction:
            
            guard let strongSelf = self else { return }
            
            // Read/write diffItems in self.diffQueue
            let diffItems = strongSelf.diffItems
            let changes = strongSelf.computeChanges(fromRows: diffItems, toRows: newItems)
            strongSelf.diffItems = newItems
            
            guard !changes.isEmpty else {
                return
            }
            
            dispatch_async(strongSelf.mainQueue) {
                // This code, submitted to the serial main queue, is guaranteed
                // to process the last database transaction:
                
                guard let strongSelf = self else { return }
                
                strongSelf.delegate?.controllerWillChangeRecords(strongSelf)
                strongSelf.mainItems = newItems
                
                for change in changes {
                    strongSelf.delegate?.controller(strongSelf, didChangeRecord: change.record, withEvent: change.event)
                }
                
                strongSelf.delegate?.controllerDidChangeRecords(strongSelf)
            }
        }
    }
}


// =============================================================================
// MARK: - FetchedRecordsControllerDelegate

/// TODO
public protocol FetchedRecordsControllerDelegate : class {
    /// TODO: document that these are called on mainQueue
    func controllerWillChangeRecords<T>(controller: FetchedRecordsController<T>)
    
    /// TODO: document that these are called on mainQueue
    func controller<T>(controller: FetchedRecordsController<T>, didChangeRecord record: T, withEvent event:FetchedRecordsEvent)
    
    /// TODO: document that these are called on mainQueue
    func controllerDidChangeRecords<T>(controller: FetchedRecordsController<T>)
}

extension FetchedRecordsControllerDelegate {
    /// TODO
    func controllerWillChangeRecords<T>(controller: FetchedRecordsController<T>) { }

    /// TODO
    func controller<T>(controller: FetchedRecordsController<T>, didChangeRecord record: T, withEvent event:FetchedRecordsEvent) { }
    
    /// TODO
    func controllerDidChangeRecords<T>(controller: FetchedRecordsController<T>) { }
}



// =============================================================================
// MARK: - FetchedRecordsSectionInfo

public struct FetchedRecordsSectionInfo<T: RowConvertible> {
    private let controller: FetchedRecordsController<T>
    public var numberOfRecords: Int {
        // We only support a single section
        return controller.mainItems.count
    }
    public var records: [T] {
        // We only support a single section
        return controller.mainItems.map { $0.record }
    }
}


// =============================================================================
// MARK: - FetchedRecordsEvent

public enum FetchedRecordsEvent {
    case Insertion(indexPath: NSIndexPath)
    case Deletion(indexPath: NSIndexPath)
    case Move(indexPath: NSIndexPath, newIndexPath: NSIndexPath, changes: [String: DatabaseValue])
    case Update(indexPath: NSIndexPath, changes: [String: DatabaseValue])
}

extension FetchedRecordsEvent: CustomStringConvertible {
    public var description: String {
        switch self {
        case .Insertion(let indexPath):
            return "Insertion at \(indexPath)"
            
        case .Deletion(let indexPath):
            return "Deletion from \(indexPath)"
            
        case .Move(let indexPath, let newIndexPath, changes: let changes):
            return "Move from \(indexPath) to \(newIndexPath) with changes: \(changes)"
            
        case .Update(let indexPath, let changes):
            return "Update at \(indexPath) with changes: \(changes)"
        }
    }
}


// =============================================================================
// MARK: - DatabaseSource

private enum DatabaseSource<T> {
    case SQL(String, StatementArguments?)
    case FetchRequest(GRDB.FetchRequest<T>)
    
    func selectStatement(db: Database) throws -> SelectStatement {
        switch self {
        case .SQL(let sql, let arguments):
            let statement = try db.selectStatement(sql)
            if let arguments = arguments {
                try statement.validateArguments(arguments)
                statement.unsafeSetArguments(arguments)
            }
            return statement
        case .FetchRequest(let request):
            return try request.selectStatement(db)
        }
    }
}


// =============================================================================
// MARK: - Item

private final class Item<T: RowConvertible> : RowConvertible, Equatable {
    let row: Row
    lazy var record: T = {
        var record = T(self.row)
        record.awakeFromFetch(row: self.row)
        return record
    }()
    
    init(_ row: Row) {
        self.row = row.copy()
    }
}

private func ==<T>(lhs: Item<T>, rhs: Item<T>) -> Bool {
    return lhs.row == rhs.row
}


// =============================================================================
// MARK: - ItemChange

private enum ItemChange<T: RowConvertible> {
    case Insertion(item: Item<T>, indexPath: NSIndexPath)
    case Deletion(item: Item<T>, indexPath: NSIndexPath)
    case Move(item: Item<T>, indexPath: NSIndexPath, newIndexPath: NSIndexPath, changes: [String: DatabaseValue])
    case Update(item: Item<T>, indexPath: NSIndexPath, changes: [String: DatabaseValue])
}

extension ItemChange {

    var record: T {
        switch self {
        case .Insertion(item: let item, indexPath: _):
            return item.record
        case .Deletion(item: let item, indexPath: _):
            return item.record
        case .Move(item: let item, indexPath: _, newIndexPath: _, changes: _):
            return item.record
        case .Update(item: let item, indexPath: _, changes: _):
            return item.record
        }
    }
    
    var event: FetchedRecordsEvent {
        switch self {
        case .Insertion(item: _, indexPath: let indexPath):
            return .Insertion(indexPath: indexPath)
        case .Deletion(item: _, indexPath: let indexPath):
            return .Deletion(indexPath: indexPath)
        case .Move(item: _, indexPath: let indexPath, newIndexPath: let newIndexPath, changes: let changes):
            return .Move(indexPath: indexPath, newIndexPath: newIndexPath, changes: changes)
        case .Update(item: _, indexPath: let indexPath, changes: let changes):
            return .Update(indexPath: indexPath, changes: changes)
        }
    }
}

extension ItemChange: CustomStringConvertible {
    var description: String {
        switch self {
        case .Insertion(let item, let indexPath):
            return "Insert \(item) at \(indexPath)"
            
        case .Deletion(let item, let indexPath):
            return "Delete \(item) from \(indexPath)"
            
        case .Move(let item, let indexPath, let newIndexPath, changes: let changes):
            return "Move \(item) from \(indexPath) to \(newIndexPath) with changes: \(changes)"
            
        case .Update(let item, let indexPath, let changes):
            return "Update \(item) at \(indexPath) with changes: \(changes)"
        }
    }
}