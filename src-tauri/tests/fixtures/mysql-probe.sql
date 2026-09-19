-- Seed for the MySQL driver tests. Mirrors the SQLite and PostgreSQL fixtures so the same
-- scenarios are checked against every relational engine.
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS users;

CREATE TABLE users (
    id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(190) UNIQUE,
    age INT,
    balance DECIMAL(12,4),
    active TINYINT(1) DEFAULT 1,
    bio TEXT,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
) COMMENT='people';

CREATE INDEX idx_users_email ON users(email);

CREATE TABLE orders (
    id INT PRIMARY KEY,
    user_id INT NOT NULL,
    total DECIMAL(10,2) NOT NULL,
    CONSTRAINT fk_orders_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);

INSERT INTO users (name, email, age, balance, bio) VALUES
    ('Ada Lovelace', 'ada@example.com', 36, 1234.5600, 'First programmer'),
    ('Grace Hopper', 'grace@example.com', 85, 980.0000, 'Compiler pioneer'),
    -- A row of NULLs, so the tests can check NULL stays distinct from the empty string.
    ('Alan Turing', 'alan@example.com', 41, NULL, NULL);

INSERT INTO orders VALUES (1, 1, 99.90), (2, 2, 12.00);
