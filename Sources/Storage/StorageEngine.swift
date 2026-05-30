import Foundation

#if canImport(SQLite3)
import SQLite3
#endif

public enum StorageError: Error {
    case openFailed
    case prepareFailed
    case executeFailed
}

public final class StorageEngine {
    #if canImport(SQLite3)
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    #endif

    public init(databaseURL: URL) throws {
        #if canImport(SQLite3)
        if sqlite3_open(databaseURL.path, &db) != SQLITE_OK {
            throw StorageError.openFailed
        }
        #else
        _ = databaseURL
        #endif
    }

    deinit {
        #if canImport(SQLite3)
        sqlite3_close(db)
        #endif
    }

    public func bootstrapSchema() throws {
        let statements = [
            """
            CREATE TABLE IF NOT EXISTS Peers (
                peer_id TEXT PRIMARY KEY,
                nickname TEXT NOT NULL,
                capabilities TEXT NOT NULL,
                last_seen REAL NOT NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS Messages (
                message_id TEXT PRIMARY KEY,
                sender TEXT NOT NULL,
                receiver TEXT NOT NULL,
                timestamp REAL NOT NULL,
                type TEXT NOT NULL,
                status TEXT NOT NULL,
                payload BLOB NOT NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS Files (
                transfer_id TEXT PRIMARY KEY,
                file_name TEXT NOT NULL,
                expected_chunks INTEGER NOT NULL,
                state TEXT NOT NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS Routes (
                destination TEXT NOT NULL,
                next_hop TEXT NOT NULL,
                cost INTEGER NOT NULL,
                latency_ms INTEGER NOT NULL,
                updated_at REAL NOT NULL,
                PRIMARY KEY(destination, next_hop)
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS Groups (
                group_id TEXT PRIMARY KEY,
                members_json TEXT NOT NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS Calls (
                call_id TEXT PRIMARY KEY,
                peer_id TEXT NOT NULL,
                media_type TEXT NOT NULL,
                state TEXT NOT NULL,
                started_at REAL NOT NULL
            );
            """
        ]

        for sql in statements {
            try execute(sql: sql)
        }
    }

    public func save(peer: PeerProfile) throws {
        let capabilities = peer.capabilities.map(\.rawValue).sorted().joined(separator: ",")
        let sql = """
        INSERT OR REPLACE INTO Peers(peer_id, nickname, capabilities, last_seen)
        VALUES(?, ?, ?, ?);
        """
        try executePrepared(sql: sql) { statement in
            bindText(statement: statement, index: 1, value: peer.peerID.value)
            bindText(statement: statement, index: 2, value: peer.nickname)
            bindText(statement: statement, index: 3, value: capabilities)
            bindDouble(statement: statement, index: 4, value: peer.lastSeenAt.timeIntervalSince1970)
        }
    }

    public func save(message: MessageEnvelope, status: OutboxStatus) throws {
        let sql = """
        INSERT OR REPLACE INTO Messages(message_id, sender, receiver, timestamp, type, status, payload)
        VALUES(?, ?, ?, ?, ?, ?, ?);
        """
        let payload = try JSONEncoder().encode(message.payload)
        try executePrepared(sql: sql) { statement in
            bindText(statement: statement, index: 1, value: message.messageID.uuidString)
            bindText(statement: statement, index: 2, value: message.sender.value)
            bindText(statement: statement, index: 3, value: message.receiver.value)
            bindDouble(statement: statement, index: 4, value: message.timestamp.timeIntervalSince1970)
            bindText(statement: statement, index: 5, value: message.type.rawValue)
            bindText(statement: statement, index: 6, value: status.rawValue)
            bindBlob(statement: statement, index: 7, value: payload)
        }
    }

    public func save(route: RouteEntry) throws {
        let sql = """
        INSERT OR REPLACE INTO Routes(destination, next_hop, cost, latency_ms, updated_at)
        VALUES(?, ?, ?, ?, ?);
        """
        try executePrepared(sql: sql) { statement in
            bindText(statement: statement, index: 1, value: route.destination.value)
            bindText(statement: statement, index: 2, value: route.nextHop.value)
            bindInt(statement: statement, index: 3, value: Int32(route.cost))
            bindInt(statement: statement, index: 4, value: Int32(route.latencyMs))
            bindDouble(statement: statement, index: 5, value: route.updatedAt.timeIntervalSince1970)
        }
    }

    private func execute(sql: String) throws {
        #if canImport(SQLite3)
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw StorageError.executeFailed
        }
        #else
        _ = sql
        #endif
    }

    private func executePrepared(sql: String, binder: (OpaquePointer?) -> Void) throws {
        #if canImport(SQLite3)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StorageError.prepareFailed
        }
        defer { sqlite3_finalize(statement) }
        binder(statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StorageError.executeFailed
        }
        #else
        _ = sql
        #endif
    }

    private func bindText(statement: OpaquePointer?, index: Int32, value: String) {
        #if canImport(SQLite3)
        sqlite3_bind_text(statement, index, (value as NSString).utf8String, -1, transient)
        #else
        _ = statement
        _ = index
        _ = value
        #endif
    }

    private func bindInt(statement: OpaquePointer?, index: Int32, value: Int32) {
        #if canImport(SQLite3)
        sqlite3_bind_int(statement, index, value)
        #else
        _ = statement
        _ = index
        _ = value
        #endif
    }

    private func bindDouble(statement: OpaquePointer?, index: Int32, value: Double) {
        #if canImport(SQLite3)
        sqlite3_bind_double(statement, index, value)
        #else
        _ = statement
        _ = index
        _ = value
        #endif
    }

    private func bindBlob(statement: OpaquePointer?, index: Int32, value: Data) {
        #if canImport(SQLite3)
        value.withUnsafeBytes { raw in
            sqlite3_bind_blob(statement, index, raw.baseAddress, Int32(raw.count), transient)
        }
        #else
        _ = statement
        _ = index
        _ = value
        #endif
    }
}

