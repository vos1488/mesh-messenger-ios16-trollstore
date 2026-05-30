import Foundation

#if canImport(SQLite3)
import SQLite3
#endif

public enum StorageError: Error {
    case openFailed
    case prepareFailed
    case executeFailed
}

public struct StoredPeerRecord: Sendable, Equatable {
    public let peerID: String
    public var nickname: String
    public var lastSeen: Date
    public var isConnected: Bool
    public var signingPublicKey: Data?
    public var agreementPublicKey: Data?
    public var fingerprint: String?
    public var isVerified: Bool
    public var keyVersion: Int
    public var trustWarning: String?
}

public struct StoredMessageRecord: Sendable, Equatable {
    public let messageID: UUID
    public var peerID: String
    public var senderID: String
    public var senderNickname: String
    public var textBody: String?
    public var timestamp: Date
    public var status: OutboxStatus
    public var attempts: Int
    public var nextRetryAt: Date?
    public var deliveredAt: Date?
    public var readAt: Date?
    public var lastError: String?
    public var isOutgoing: Bool
    public var isRead: Bool
    public var ttl: Int
    public var relayPath: [String]
    public var sessionID: String?
    public var ratchetCounter: Int?
    public var nonce: Data?
    public var ciphertext: Data?
    public var tag: Data?
    public var fileID: UUID?
    public var fileName: String?
    public var fileChunkIndex: Int?
    public var fileTotalChunks: Int?
    public var fileChunkData: Data?
    public var fileChecksum: Data?
}

public struct StoredRatchetSession: Sendable, Equatable {
    public let peerID: String
    public var sessionID: String
    public var rootKey: Data
    public var sendChainKey: Data
    public var recvChainKey: Data
    public var sendCounter: Int
    public var recvCounter: Int
    public var updatedAt: Date
}

public struct StoredFileTransferRecord: Sendable, Equatable {
    public let fileID: UUID
    public var peerID: String
    public var displayName: String
    public var sizeBytes: Int
    public var chunkSize: Int
    public var totalChunks: Int
    public var completedChunks: Int
    public var state: String
    public var checksum: Data?
    public var updatedAt: Date
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
            CREATE TABLE IF NOT EXISTS Meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            """,
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
            """,
            """
            CREATE TABLE IF NOT EXISTS ChatPeers (
                peer_id TEXT PRIMARY KEY,
                nickname TEXT NOT NULL,
                last_seen REAL NOT NULL,
                is_connected INTEGER NOT NULL DEFAULT 0,
                signing_public_key BLOB,
                agreement_public_key BLOB,
                fingerprint TEXT,
                is_verified INTEGER NOT NULL DEFAULT 0,
                key_version INTEGER NOT NULL DEFAULT 1,
                trust_warning TEXT,
                updated_at REAL NOT NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS ChatMessages (
                message_id TEXT PRIMARY KEY,
                peer_id TEXT NOT NULL,
                sender_id TEXT NOT NULL,
                sender_nickname TEXT NOT NULL,
                text_body TEXT,
                timestamp REAL NOT NULL,
                status TEXT NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0,
                next_retry_at REAL,
                delivered_at REAL,
                read_at REAL,
                last_error TEXT,
                is_outgoing INTEGER NOT NULL,
                is_read INTEGER NOT NULL DEFAULT 0,
                ttl INTEGER NOT NULL DEFAULT 16,
                relay_path TEXT NOT NULL DEFAULT '[]',
                session_id TEXT,
                ratchet_counter INTEGER,
                nonce BLOB,
                ciphertext BLOB,
                tag BLOB,
                file_id TEXT,
                file_name TEXT,
                file_chunk_index INTEGER,
                file_total_chunks INTEGER,
                file_chunk_data BLOB,
                file_checksum BLOB
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS RatchetSessions (
                peer_id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                root_key BLOB NOT NULL,
                send_chain_key BLOB NOT NULL,
                recv_chain_key BLOB NOT NULL,
                send_counter INTEGER NOT NULL,
                recv_counter INTEGER NOT NULL,
                updated_at REAL NOT NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS FileTransfers (
                file_id TEXT PRIMARY KEY,
                peer_id TEXT NOT NULL,
                display_name TEXT NOT NULL,
                size_bytes INTEGER NOT NULL,
                chunk_size INTEGER NOT NULL,
                total_chunks INTEGER NOT NULL,
                completed_chunks INTEGER NOT NULL DEFAULT 0,
                state TEXT NOT NULL,
                checksum BLOB,
                updated_at REAL NOT NULL
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_chat_messages_peer_time ON ChatMessages(peer_id, timestamp DESC);",
            "CREATE INDEX IF NOT EXISTS idx_chat_messages_status_retry ON ChatMessages(status, next_retry_at);",
            "CREATE INDEX IF NOT EXISTS idx_chat_messages_sender ON ChatMessages(sender_id);",
            "CREATE INDEX IF NOT EXISTS idx_routes_destination ON Routes(destination, updated_at DESC);",
            "CREATE INDEX IF NOT EXISTS idx_file_transfers_peer ON FileTransfers(peer_id, updated_at DESC);"
        ]

        for sql in statements {
            try execute(sql: sql)
        }

        try execute(sql: "INSERT OR REPLACE INTO Meta(key, value) VALUES('schema_version', '2');")
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

    public func upsertChatPeer(_ peer: StoredPeerRecord) throws {
        let sql = """
        INSERT INTO ChatPeers(
            peer_id, nickname, last_seen, is_connected, signing_public_key, agreement_public_key,
            fingerprint, is_verified, key_version, trust_warning, updated_at
        ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(peer_id) DO UPDATE SET
            nickname = excluded.nickname,
            last_seen = excluded.last_seen,
            is_connected = excluded.is_connected,
            signing_public_key = excluded.signing_public_key,
            agreement_public_key = excluded.agreement_public_key,
            fingerprint = excluded.fingerprint,
            is_verified = excluded.is_verified,
            key_version = excluded.key_version,
            trust_warning = excluded.trust_warning,
            updated_at = excluded.updated_at;
        """
        try executePrepared(sql: sql) { statement in
            bindText(statement: statement, index: 1, value: peer.peerID)
            bindText(statement: statement, index: 2, value: peer.nickname)
            bindDouble(statement: statement, index: 3, value: peer.lastSeen.timeIntervalSince1970)
            bindInt(statement: statement, index: 4, value: peer.isConnected ? 1 : 0)
            bindBlob(statement: statement, index: 5, value: peer.signingPublicKey)
            bindBlob(statement: statement, index: 6, value: peer.agreementPublicKey)
            bindText(statement: statement, index: 7, value: peer.fingerprint)
            bindInt(statement: statement, index: 8, value: peer.isVerified ? 1 : 0)
            bindInt(statement: statement, index: 9, value: Int32(peer.keyVersion))
            bindText(statement: statement, index: 10, value: peer.trustWarning)
            bindDouble(statement: statement, index: 11, value: Date().timeIntervalSince1970)
        }
    }

    public func fetchChatPeers() throws -> [StoredPeerRecord] {
        let sql = """
        SELECT peer_id, nickname, last_seen, is_connected, signing_public_key, agreement_public_key,
               fingerprint, is_verified, key_version, trust_warning
        FROM ChatPeers
        ORDER BY last_seen DESC;
        """
        return try queryPrepared(sql: sql) { statement in
            guard let peerID = columnText(statement: statement, index: 0),
                  let nickname = columnText(statement: statement, index: 1) else {
                return nil
            }
            return StoredPeerRecord(
                peerID: peerID,
                nickname: nickname,
                lastSeen: Date(timeIntervalSince1970: columnDouble(statement: statement, index: 2)),
                isConnected: columnInt(statement: statement, index: 3) != 0,
                signingPublicKey: columnBlob(statement: statement, index: 4),
                agreementPublicKey: columnBlob(statement: statement, index: 5),
                fingerprint: columnText(statement: statement, index: 6),
                isVerified: columnInt(statement: statement, index: 7) != 0,
                keyVersion: Int(columnInt(statement: statement, index: 8)),
                trustWarning: columnText(statement: statement, index: 9)
            )
        }
    }

    public func upsertChatMessage(_ record: StoredMessageRecord) throws {
        let sql = """
        INSERT INTO ChatMessages(
            message_id, peer_id, sender_id, sender_nickname, text_body, timestamp, status, attempts,
            next_retry_at, delivered_at, read_at, last_error, is_outgoing, is_read, ttl, relay_path,
            session_id, ratchet_counter, nonce, ciphertext, tag, file_id, file_name, file_chunk_index,
            file_total_chunks, file_chunk_data, file_checksum
        ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(message_id) DO UPDATE SET
            peer_id = excluded.peer_id,
            sender_id = excluded.sender_id,
            sender_nickname = excluded.sender_nickname,
            text_body = excluded.text_body,
            timestamp = excluded.timestamp,
            status = excluded.status,
            attempts = excluded.attempts,
            next_retry_at = excluded.next_retry_at,
            delivered_at = excluded.delivered_at,
            read_at = excluded.read_at,
            last_error = excluded.last_error,
            is_outgoing = excluded.is_outgoing,
            is_read = excluded.is_read,
            ttl = excluded.ttl,
            relay_path = excluded.relay_path,
            session_id = excluded.session_id,
            ratchet_counter = excluded.ratchet_counter,
            nonce = excluded.nonce,
            ciphertext = excluded.ciphertext,
            tag = excluded.tag,
            file_id = excluded.file_id,
            file_name = excluded.file_name,
            file_chunk_index = excluded.file_chunk_index,
            file_total_chunks = excluded.file_total_chunks,
            file_chunk_data = excluded.file_chunk_data,
            file_checksum = excluded.file_checksum;
        """
        let relayData = try JSONEncoder().encode(record.relayPath)
        let relayString = String(decoding: relayData, as: UTF8.self)
        try executePrepared(sql: sql) { statement in
            bindText(statement: statement, index: 1, value: record.messageID.uuidString)
            bindText(statement: statement, index: 2, value: record.peerID)
            bindText(statement: statement, index: 3, value: record.senderID)
            bindText(statement: statement, index: 4, value: record.senderNickname)
            bindText(statement: statement, index: 5, value: record.textBody)
            bindDouble(statement: statement, index: 6, value: record.timestamp.timeIntervalSince1970)
            bindText(statement: statement, index: 7, value: record.status.rawValue)
            bindInt(statement: statement, index: 8, value: Int32(record.attempts))
            bindDouble(statement: statement, index: 9, value: record.nextRetryAt?.timeIntervalSince1970)
            bindDouble(statement: statement, index: 10, value: record.deliveredAt?.timeIntervalSince1970)
            bindDouble(statement: statement, index: 11, value: record.readAt?.timeIntervalSince1970)
            bindText(statement: statement, index: 12, value: record.lastError)
            bindInt(statement: statement, index: 13, value: record.isOutgoing ? 1 : 0)
            bindInt(statement: statement, index: 14, value: record.isRead ? 1 : 0)
            bindInt(statement: statement, index: 15, value: Int32(record.ttl))
            bindText(statement: statement, index: 16, value: relayString)
            bindText(statement: statement, index: 17, value: record.sessionID)
            bindInt(statement: statement, index: 18, value: record.ratchetCounter.map { Int32($0) })
            bindBlob(statement: statement, index: 19, value: record.nonce)
            bindBlob(statement: statement, index: 20, value: record.ciphertext)
            bindBlob(statement: statement, index: 21, value: record.tag)
            bindText(statement: statement, index: 22, value: record.fileID?.uuidString)
            bindText(statement: statement, index: 23, value: record.fileName)
            bindInt(statement: statement, index: 24, value: record.fileChunkIndex.map { Int32($0) })
            bindInt(statement: statement, index: 25, value: record.fileTotalChunks.map { Int32($0) })
            bindBlob(statement: statement, index: 26, value: record.fileChunkData)
            bindBlob(statement: statement, index: 27, value: record.fileChecksum)
        }
    }

    public func fetchChatMessages(peerID: String, limit: Int = 500) throws -> [StoredMessageRecord] {
        let sql = """
        SELECT message_id, peer_id, sender_id, sender_nickname, text_body, timestamp, status, attempts,
               next_retry_at, delivered_at, read_at, last_error, is_outgoing, is_read, ttl, relay_path,
               session_id, ratchet_counter, nonce, ciphertext, tag, file_id, file_name, file_chunk_index,
               file_total_chunks, file_chunk_data, file_checksum
        FROM ChatMessages
        WHERE peer_id = ?
        ORDER BY timestamp ASC
        LIMIT ?;
        """
        return try queryPrepared(sql: sql, binder: { statement in
            bindText(statement: statement, index: 1, value: peerID)
            bindInt(statement: statement, index: 2, value: Int32(limit))
        }, rowMapper: { [self] statement in
            mapMessageRow(statement: statement)
        })
    }

    public func fetchDueOutgoingMessages(now: Date, limit: Int = 64) throws -> [StoredMessageRecord] {
        let sql = """
        SELECT message_id, peer_id, sender_id, sender_nickname, text_body, timestamp, status, attempts,
               next_retry_at, delivered_at, read_at, last_error, is_outgoing, is_read, ttl, relay_path,
               session_id, ratchet_counter, nonce, ciphertext, tag, file_id, file_name, file_chunk_index,
               file_total_chunks, file_chunk_data, file_checksum
        FROM ChatMessages
        WHERE is_outgoing = 1
          AND status IN ('queued', 'pending', 'sent', 'failed')
          AND (next_retry_at IS NULL OR next_retry_at <= ?)
        ORDER BY COALESCE(next_retry_at, timestamp) ASC
        LIMIT ?;
        """
        return try queryPrepared(sql: sql, binder: { statement in
            bindDouble(statement: statement, index: 1, value: now.timeIntervalSince1970)
            bindInt(statement: statement, index: 2, value: Int32(limit))
        }, rowMapper: { [self] statement in
            mapMessageRow(statement: statement)
        })
    }

    public func hasMessage(messageID: UUID) throws -> Bool {
        let sql = "SELECT 1 FROM ChatMessages WHERE message_id = ? LIMIT 1;"
        let rows: [Int] = try queryPrepared(sql: sql, binder: { statement in
            bindText(statement: statement, index: 1, value: messageID.uuidString)
        }, rowMapper: { statement in
            Int(columnInt(statement: statement, index: 0))
        })
        return !rows.isEmpty
    }

    public func markMessageStatus(
        messageID: UUID,
        status: OutboxStatus,
        attempts: Int? = nil,
        nextRetryAt: Date? = nil,
        deliveredAt: Date? = nil,
        readAt: Date? = nil,
        lastError: String? = nil
    ) throws {
        let sql = """
        UPDATE ChatMessages
        SET status = ?,
            attempts = COALESCE(?, attempts),
            next_retry_at = ?,
            delivered_at = COALESCE(?, delivered_at),
            read_at = COALESCE(?, read_at),
            last_error = ?
        WHERE message_id = ?;
        """
        try executePrepared(sql: sql) { statement in
            bindText(statement: statement, index: 1, value: status.rawValue)
            bindInt(statement: statement, index: 2, value: attempts.map { Int32($0) })
            bindDouble(statement: statement, index: 3, value: nextRetryAt?.timeIntervalSince1970)
            bindDouble(statement: statement, index: 4, value: deliveredAt?.timeIntervalSince1970)
            bindDouble(statement: statement, index: 5, value: readAt?.timeIntervalSince1970)
            bindText(statement: statement, index: 6, value: lastError)
            bindText(statement: statement, index: 7, value: messageID.uuidString)
        }
    }

    public func markPeerMessagesRead(peerID: String, myPeerID: String, at readAt: Date) throws -> [UUID] {
        let fetchSQL = """
        SELECT message_id FROM ChatMessages
        WHERE peer_id = ? AND is_outgoing = 0 AND sender_id = ? AND is_read = 0;
        """
        let ids: [UUID] = try queryPrepared(sql: fetchSQL, binder: { statement in
            bindText(statement: statement, index: 1, value: peerID)
            bindText(statement: statement, index: 2, value: peerID)
        }, rowMapper: { statement in
            guard let value = columnText(statement: statement, index: 0) else { return nil }
            return UUID(uuidString: value)
        })

        let updateSQL = """
        UPDATE ChatMessages
        SET is_read = 1, read_at = ?, status = CASE WHEN is_outgoing = 0 THEN 'read' ELSE status END
        WHERE peer_id = ? AND sender_id = ? AND is_outgoing = 0;
        """
        try executePrepared(sql: updateSQL) { statement in
            bindDouble(statement: statement, index: 1, value: readAt.timeIntervalSince1970)
            bindText(statement: statement, index: 2, value: peerID)
            bindText(statement: statement, index: 3, value: peerID)
        }
        _ = myPeerID
        return ids
    }

    public func markOutgoingAsRead(messageID: UUID, at readAt: Date) throws {
        let sql = """
        UPDATE ChatMessages
        SET status = 'read', read_at = ?, is_read = 1
        WHERE message_id = ? AND is_outgoing = 1;
        """
        try executePrepared(sql: sql) { statement in
            bindDouble(statement: statement, index: 1, value: readAt.timeIntervalSince1970)
            bindText(statement: statement, index: 2, value: messageID.uuidString)
        }
    }

    public func searchMessages(query: String, peerID: String? = nil, limit: Int = 100) throws -> [StoredMessageRecord] {
        let q = "%\(query.lowercased())%"
        if let peerID {
            let sql = """
            SELECT message_id, peer_id, sender_id, sender_nickname, text_body, timestamp, status, attempts,
                   next_retry_at, delivered_at, read_at, last_error, is_outgoing, is_read, ttl, relay_path,
                   session_id, ratchet_counter, nonce, ciphertext, tag, file_id, file_name, file_chunk_index,
                   file_total_chunks, file_chunk_data, file_checksum
            FROM ChatMessages
            WHERE peer_id = ? AND LOWER(COALESCE(text_body, '')) LIKE ?
            ORDER BY timestamp DESC
            LIMIT ?;
            """
            return try queryPrepared(sql: sql, binder: { statement in
                bindText(statement: statement, index: 1, value: peerID)
                bindText(statement: statement, index: 2, value: q)
                bindInt(statement: statement, index: 3, value: Int32(limit))
            }, rowMapper: { [self] statement in
                mapMessageRow(statement: statement)
            })
        }

        let sql = """
        SELECT message_id, peer_id, sender_id, sender_nickname, text_body, timestamp, status, attempts,
               next_retry_at, delivered_at, read_at, last_error, is_outgoing, is_read, ttl, relay_path,
               session_id, ratchet_counter, nonce, ciphertext, tag, file_id, file_name, file_chunk_index,
               file_total_chunks, file_chunk_data, file_checksum
        FROM ChatMessages
        WHERE LOWER(COALESCE(text_body, '')) LIKE ?
        ORDER BY timestamp DESC
        LIMIT ?;
        """
        return try queryPrepared(sql: sql, binder: { statement in
            bindText(statement: statement, index: 1, value: q)
            bindInt(statement: statement, index: 2, value: Int32(limit))
        }, rowMapper: { [self] statement in
            mapMessageRow(statement: statement)
        })
    }

    public func upsertRatchetSession(_ session: StoredRatchetSession) throws {
        let sql = """
        INSERT INTO RatchetSessions(
            peer_id, session_id, root_key, send_chain_key, recv_chain_key, send_counter, recv_counter, updated_at
        ) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(peer_id) DO UPDATE SET
            session_id = excluded.session_id,
            root_key = excluded.root_key,
            send_chain_key = excluded.send_chain_key,
            recv_chain_key = excluded.recv_chain_key,
            send_counter = excluded.send_counter,
            recv_counter = excluded.recv_counter,
            updated_at = excluded.updated_at;
        """
        try executePrepared(sql: sql) { statement in
            bindText(statement: statement, index: 1, value: session.peerID)
            bindText(statement: statement, index: 2, value: session.sessionID)
            bindBlob(statement: statement, index: 3, value: session.rootKey)
            bindBlob(statement: statement, index: 4, value: session.sendChainKey)
            bindBlob(statement: statement, index: 5, value: session.recvChainKey)
            bindInt(statement: statement, index: 6, value: Int32(session.sendCounter))
            bindInt(statement: statement, index: 7, value: Int32(session.recvCounter))
            bindDouble(statement: statement, index: 8, value: session.updatedAt.timeIntervalSince1970)
        }
    }

    public func ratchetSession(peerID: String) throws -> StoredRatchetSession? {
        let sql = """
        SELECT peer_id, session_id, root_key, send_chain_key, recv_chain_key, send_counter, recv_counter, updated_at
        FROM RatchetSessions
        WHERE peer_id = ?
        LIMIT 1;
        """
        let rows: [StoredRatchetSession] = try queryPrepared(sql: sql, binder: { statement in
            bindText(statement: statement, index: 1, value: peerID)
        }, rowMapper: { statement in
            guard let peerID = columnText(statement: statement, index: 0),
                  let sessionID = columnText(statement: statement, index: 1),
                  let root = columnBlob(statement: statement, index: 2),
                  let send = columnBlob(statement: statement, index: 3),
                  let recv = columnBlob(statement: statement, index: 4) else {
                return nil
            }
            return StoredRatchetSession(
                peerID: peerID,
                sessionID: sessionID,
                rootKey: root,
                sendChainKey: send,
                recvChainKey: recv,
                sendCounter: Int(columnInt(statement: statement, index: 5)),
                recvCounter: Int(columnInt(statement: statement, index: 6)),
                updatedAt: Date(timeIntervalSince1970: columnDouble(statement: statement, index: 7))
            )
        })
        return rows.first
    }

    public func upsertFileTransfer(_ record: StoredFileTransferRecord) throws {
        let sql = """
        INSERT INTO FileTransfers(
            file_id, peer_id, display_name, size_bytes, chunk_size, total_chunks, completed_chunks, state, checksum, updated_at
        ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(file_id) DO UPDATE SET
            peer_id = excluded.peer_id,
            display_name = excluded.display_name,
            size_bytes = excluded.size_bytes,
            chunk_size = excluded.chunk_size,
            total_chunks = excluded.total_chunks,
            completed_chunks = excluded.completed_chunks,
            state = excluded.state,
            checksum = excluded.checksum,
            updated_at = excluded.updated_at;
        """
        try executePrepared(sql: sql) { statement in
            bindText(statement: statement, index: 1, value: record.fileID.uuidString)
            bindText(statement: statement, index: 2, value: record.peerID)
            bindText(statement: statement, index: 3, value: record.displayName)
            bindInt(statement: statement, index: 4, value: Int32(record.sizeBytes))
            bindInt(statement: statement, index: 5, value: Int32(record.chunkSize))
            bindInt(statement: statement, index: 6, value: Int32(record.totalChunks))
            bindInt(statement: statement, index: 7, value: Int32(record.completedChunks))
            bindText(statement: statement, index: 8, value: record.state)
            bindBlob(statement: statement, index: 9, value: record.checksum)
            bindDouble(statement: statement, index: 10, value: record.updatedAt.timeIntervalSince1970)
        }
    }

    public func fileTransfer(fileID: UUID) throws -> StoredFileTransferRecord? {
        let sql = """
        SELECT file_id, peer_id, display_name, size_bytes, chunk_size, total_chunks, completed_chunks, state, checksum, updated_at
        FROM FileTransfers
        WHERE file_id = ?
        LIMIT 1;
        """
        let rows: [StoredFileTransferRecord] = try queryPrepared(sql: sql, binder: { statement in
            bindText(statement: statement, index: 1, value: fileID.uuidString)
        }, rowMapper: { statement in
            guard let idStr = columnText(statement: statement, index: 0),
                  let id = UUID(uuidString: idStr),
                  let peerID = columnText(statement: statement, index: 1),
                  let display = columnText(statement: statement, index: 2),
                  let state = columnText(statement: statement, index: 7) else {
                return nil
            }
            return StoredFileTransferRecord(
                fileID: id,
                peerID: peerID,
                displayName: display,
                sizeBytes: Int(columnInt(statement: statement, index: 3)),
                chunkSize: Int(columnInt(statement: statement, index: 4)),
                totalChunks: Int(columnInt(statement: statement, index: 5)),
                completedChunks: Int(columnInt(statement: statement, index: 6)),
                state: state,
                checksum: columnBlob(statement: statement, index: 8),
                updatedAt: Date(timeIntervalSince1970: columnDouble(statement: statement, index: 9))
            )
        })
        return rows.first
    }

    private func mapMessageRow(statement: OpaquePointer?) -> StoredMessageRecord? {
        guard let messageIDString = columnText(statement: statement, index: 0),
              let messageID = UUID(uuidString: messageIDString),
              let peerID = columnText(statement: statement, index: 1),
              let senderID = columnText(statement: statement, index: 2),
              let senderNickname = columnText(statement: statement, index: 3),
              let statusRaw = columnText(statement: statement, index: 6),
              let status = OutboxStatus(rawValue: statusRaw) else {
            return nil
        }
        let relayPathString = columnText(statement: statement, index: 15) ?? "[]"
        let relayPathData = Data(relayPathString.utf8)
        let relayPath = (try? JSONDecoder().decode([String].self, from: relayPathData)) ?? []
        return StoredMessageRecord(
            messageID: messageID,
            peerID: peerID,
            senderID: senderID,
            senderNickname: senderNickname,
            textBody: columnText(statement: statement, index: 4),
            timestamp: Date(timeIntervalSince1970: columnDouble(statement: statement, index: 5)),
            status: status,
            attempts: Int(columnInt(statement: statement, index: 7)),
            nextRetryAt: columnOptionalDate(statement: statement, index: 8),
            deliveredAt: columnOptionalDate(statement: statement, index: 9),
            readAt: columnOptionalDate(statement: statement, index: 10),
            lastError: columnText(statement: statement, index: 11),
            isOutgoing: columnInt(statement: statement, index: 12) != 0,
            isRead: columnInt(statement: statement, index: 13) != 0,
            ttl: Int(columnInt(statement: statement, index: 14)),
            relayPath: relayPath,
            sessionID: columnText(statement: statement, index: 16),
            ratchetCounter: columnOptionalInt(statement: statement, index: 17),
            nonce: columnBlob(statement: statement, index: 18),
            ciphertext: columnBlob(statement: statement, index: 19),
            tag: columnBlob(statement: statement, index: 20),
            fileID: columnText(statement: statement, index: 21).flatMap(UUID.init(uuidString:)),
            fileName: columnText(statement: statement, index: 22),
            fileChunkIndex: columnOptionalInt(statement: statement, index: 23),
            fileTotalChunks: columnOptionalInt(statement: statement, index: 24),
            fileChunkData: columnBlob(statement: statement, index: 25),
            fileChecksum: columnBlob(statement: statement, index: 26)
        )
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

    private func queryPrepared<T>(
        sql: String,
        binder: (OpaquePointer?) -> Void = { _ in },
        rowMapper: (OpaquePointer?) -> T?
    ) throws -> [T] {
        #if canImport(SQLite3)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StorageError.prepareFailed
        }
        defer { sqlite3_finalize(statement) }
        binder(statement)

        var result: [T] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                if let item = rowMapper(statement) {
                    result.append(item)
                }
            } else if step == SQLITE_DONE {
                break
            } else {
                throw StorageError.executeFailed
            }
        }
        return result
        #else
        _ = sql
        _ = binder
        _ = rowMapper
        return []
        #endif
    }

    private func bindText(statement: OpaquePointer?, index: Int32, value: String?) {
        #if canImport(SQLite3)
        if let value {
            sqlite3_bind_text(statement, index, (value as NSString).utf8String, -1, transient)
        } else {
            sqlite3_bind_null(statement, index)
        }
        #else
        _ = statement
        _ = index
        _ = value
        #endif
    }

    private func bindInt(statement: OpaquePointer?, index: Int32, value: Int32?) {
        #if canImport(SQLite3)
        if let value {
            sqlite3_bind_int(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
        #else
        _ = statement
        _ = index
        _ = value
        #endif
    }

    private func bindDouble(statement: OpaquePointer?, index: Int32, value: Double?) {
        #if canImport(SQLite3)
        if let value {
            sqlite3_bind_double(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
        #else
        _ = statement
        _ = index
        _ = value
        #endif
    }

    private func bindBlob(statement: OpaquePointer?, index: Int32, value: Data?) {
        #if canImport(SQLite3)
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        _ = value.withUnsafeBytes { raw in
            sqlite3_bind_blob(statement, index, raw.baseAddress, Int32(raw.count), transient)
        }
        #else
        _ = statement
        _ = index
        _ = value
        #endif
    }

    private func columnText(statement: OpaquePointer?, index: Int32) -> String? {
        #if canImport(SQLite3)
        guard let ptr = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: ptr)
        #else
        _ = statement
        _ = index
        return nil
        #endif
    }

    private func columnInt(statement: OpaquePointer?, index: Int32) -> Int32 {
        #if canImport(SQLite3)
        sqlite3_column_int(statement, index)
        #else
        _ = statement
        _ = index
        return 0
        #endif
    }

    private func columnDouble(statement: OpaquePointer?, index: Int32) -> Double {
        #if canImport(SQLite3)
        sqlite3_column_double(statement, index)
        #else
        _ = statement
        _ = index
        return 0
        #endif
    }

    private func columnBlob(statement: OpaquePointer?, index: Int32) -> Data? {
        #if canImport(SQLite3)
        let count = sqlite3_column_bytes(statement, index)
        guard count > 0, let ptr = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: ptr, count: Int(count))
        #else
        _ = statement
        _ = index
        return nil
        #endif
    }

    private func columnOptionalDate(statement: OpaquePointer?, index: Int32) -> Date? {
        #if canImport(SQLite3)
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
        #else
        _ = statement
        _ = index
        return nil
        #endif
    }

    private func columnOptionalInt(statement: OpaquePointer?, index: Int32) -> Int? {
        #if canImport(SQLite3)
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int(statement, index))
        #else
        _ = statement
        _ = index
        return nil
        #endif
    }
}
