/// Versioned schema migrations. `PRAGMA user_version` holds the applied version.
///
/// Rules: never edit a released migration; append a new one. Each migration
/// runs inside the open transaction managed by sqflite's onCreate/onUpgrade.
const int kSchemaVersion = 1;

final Map<int, List<String>> migrations = {
  1: _v1,
};

const _v1 = <String>[
  '''
  CREATE TABLE app_meta (
    key TEXT PRIMARY KEY NOT NULL,
    value TEXT
  )''',
  '''
  CREATE TABLE users (
    id TEXT PRIMARY KEY NOT NULL,
    display_name TEXT NOT NULL,
    avatar_path TEXT,
    ed25519_pub TEXT,
    x25519_pub TEXT,
    is_local INTEGER NOT NULL DEFAULT 0 CHECK (is_local IN (0, 1)),
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
  )''',
  '''
  CREATE TABLE friends (
    user_id TEXT PRIMARY KEY NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    note TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    deleted_at INTEGER
  )''',
  '''
  CREATE TABLE groups (
    id TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL,
    type TEXT NOT NULL CHECK (type IN ('group', 'direct')),
    default_currency TEXT NOT NULL,
    created_by TEXT NOT NULL REFERENCES users(id),
    archived INTEGER NOT NULL DEFAULT 0 CHECK (archived IN (0, 1)),
    local_status TEXT NOT NULL DEFAULT 'active'
      CHECK (local_status IN ('active', 'invited', 'declined')),
    head_change_id TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    deleted_at INTEGER
  )''',
  '''
  CREATE TABLE group_members (
    id TEXT PRIMARY KEY NOT NULL,
    group_id TEXT NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    user_id TEXT NOT NULL REFERENCES users(id),
    role TEXT NOT NULL CHECK (role IN ('admin', 'member')),
    status TEXT NOT NULL CHECK (status IN ('active', 'removed')),
    joined_hlc TEXT NOT NULL,
    removed_hlc TEXT,
    head_change_id TEXT,
    updated_at INTEGER NOT NULL,
    UNIQUE (group_id, user_id)
  )''',
  'CREATE INDEX idx_group_members_user ON group_members(user_id)',
  '''
  CREATE TABLE group_invitations (
    id TEXT PRIMARY KEY NOT NULL,
    group_id TEXT REFERENCES groups(id) ON DELETE CASCADE,
    token_hash TEXT NOT NULL,
    created_by TEXT NOT NULL REFERENCES users(id),
    placeholder_user_id TEXT REFERENCES users(id),
    status TEXT NOT NULL CHECK (status IN ('open', 'used', 'expired', 'revoked')),
    expires_at INTEGER NOT NULL,
    used_by_user_id TEXT,
    created_at INTEGER NOT NULL
  )''',
  '''
  CREATE TABLE expenses (
    id TEXT PRIMARY KEY NOT NULL,
    group_id TEXT NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    description TEXT NOT NULL,
    amount_minor INTEGER NOT NULL CHECK (amount_minor > 0),
    currency TEXT NOT NULL CHECK (length(currency) = 3),
    payer_id TEXT NOT NULL REFERENCES users(id),
    split_type TEXT NOT NULL CHECK (split_type IN ('equal', 'exact', 'percentage', 'shares')),
    expense_date INTEGER NOT NULL,
    category TEXT NOT NULL DEFAULT 'general',
    notes TEXT,
    receipt_path TEXT,
    created_by TEXT NOT NULL REFERENCES users(id),
    conflicted INTEGER NOT NULL DEFAULT 0 CHECK (conflicted IN (0, 1)),
    head_change_id TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    deleted_at INTEGER
  )''',
  'CREATE INDEX idx_expenses_group_date ON expenses(group_id, expense_date)',
  'CREATE INDEX idx_expenses_payer ON expenses(payer_id)',
  '''
  CREATE TABLE expense_participants (
    expense_id TEXT NOT NULL REFERENCES expenses(id) ON DELETE CASCADE,
    user_id TEXT NOT NULL REFERENCES users(id),
    input_value INTEGER NOT NULL CHECK (input_value >= 0),
    PRIMARY KEY (expense_id, user_id)
  )''',
  '''
  CREATE TABLE expense_splits (
    expense_id TEXT NOT NULL REFERENCES expenses(id) ON DELETE CASCADE,
    user_id TEXT NOT NULL REFERENCES users(id),
    owed_minor INTEGER NOT NULL CHECK (owed_minor >= 0),
    PRIMARY KEY (expense_id, user_id)
  )''',
  'CREATE INDEX idx_expense_splits_user ON expense_splits(user_id)',
  '''
  CREATE TABLE settlements (
    id TEXT PRIMARY KEY NOT NULL,
    group_id TEXT NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    from_user_id TEXT NOT NULL REFERENCES users(id),
    to_user_id TEXT NOT NULL REFERENCES users(id),
    amount_minor INTEGER NOT NULL CHECK (amount_minor > 0),
    currency TEXT NOT NULL CHECK (length(currency) = 3),
    settled_at INTEGER NOT NULL,
    method TEXT NOT NULL DEFAULT 'cash',
    note TEXT,
    created_by TEXT NOT NULL REFERENCES users(id),
    created_device_id TEXT NOT NULL,
    conflicted INTEGER NOT NULL DEFAULT 0 CHECK (conflicted IN (0, 1)),
    head_change_id TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    voided_at INTEGER,
    void_reason TEXT,
    CHECK (from_user_id <> to_user_id)
  )''',
  'CREATE INDEX idx_settlements_group ON settlements(group_id)',
  '''
  CREATE TABLE activity_logs (
    id TEXT PRIMARY KEY NOT NULL,
    group_id TEXT,
    entity_type TEXT NOT NULL,
    entity_id TEXT NOT NULL,
    action TEXT NOT NULL,
    actor_id TEXT NOT NULL,
    summary TEXT NOT NULL,
    change_id TEXT NOT NULL UNIQUE,
    is_remote INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL
  )''',
  'CREATE INDEX idx_activity_created ON activity_logs(created_at)',
  'CREATE INDEX idx_activity_group ON activity_logs(group_id, created_at)',
  '''
  CREATE TABLE sync_devices (
    device_id TEXT PRIMARY KEY NOT NULL,
    user_id TEXT NOT NULL REFERENCES users(id),
    ed25519_pub TEXT NOT NULL,
    x25519_pub TEXT NOT NULL,
    display_name TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'paired' CHECK (status IN ('paired', 'revoked')),
    paired_at INTEGER NOT NULL,
    last_sync_at INTEGER,
    last_endpoint TEXT,
    peer_vector TEXT NOT NULL DEFAULT '{}'
  )''',
  'CREATE INDEX idx_sync_devices_user ON sync_devices(user_id)',
  '''
  CREATE TABLE sync_changes (
    change_id TEXT PRIMARY KEY NOT NULL,
    format_version INTEGER NOT NULL,
    entity_type TEXT NOT NULL,
    entity_id TEXT NOT NULL,
    group_id TEXT NOT NULL,
    parents TEXT NOT NULL,
    author_user_id TEXT NOT NULL,
    origin_device_id TEXT NOT NULL,
    origin_seq INTEGER NOT NULL,
    hlc TEXT NOT NULL,
    payload TEXT NOT NULL,
    signature TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('applied', 'pending', 'rejected')),
    status_reason TEXT,
    is_local INTEGER NOT NULL DEFAULT 0,
    received_at INTEGER NOT NULL,
    UNIQUE (origin_device_id, origin_seq)
  )''',
  'CREATE INDEX idx_sync_changes_entity ON sync_changes(entity_type, entity_id)',
  'CREATE INDEX idx_sync_changes_scope ON sync_changes(group_id, origin_device_id, origin_seq)',
  'CREATE INDEX idx_sync_changes_status ON sync_changes(status)',
  '''
  CREATE TABLE sync_conflicts (
    id TEXT PRIMARY KEY NOT NULL,
    entity_type TEXT NOT NULL,
    entity_id TEXT NOT NULL,
    group_id TEXT NOT NULL,
    kind TEXT NOT NULL,
    head_ids TEXT NOT NULL,
    details TEXT,
    detected_at INTEGER NOT NULL,
    resolved_at INTEGER,
    resolution TEXT,
    UNIQUE (entity_type, entity_id, kind)
  )''',
  '''
  CREATE TABLE backup_metadata (
    id TEXT PRIMARY KEY NOT NULL,
    direction TEXT NOT NULL CHECK (direction IN ('backup', 'restore')),
    location TEXT NOT NULL,
    remote_id TEXT,
    file_name TEXT NOT NULL,
    size_bytes INTEGER NOT NULL,
    payload_sha256 TEXT NOT NULL,
    schema_version INTEGER NOT NULL,
    format_version INTEGER NOT NULL,
    created_at INTEGER NOT NULL
  )''',
];
