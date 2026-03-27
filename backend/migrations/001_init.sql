-- ============================================
-- Схема базы данных маркетплейса
-- ============================================

-- Включаем расширение UUID
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";


-- TODO: Создать таблицу order_statuses
-- Столбцы: status (PK), description
CREATE TABLE order_statuses (
    status      VARCHAR(20) PRIMARY KEY,
    description TEXT
);

-- TODO: Вставить значения статусов
-- created, paid, cancelled, shipped, completed
INSERT INTO order_statuses (status, description) VALUES
    ('created',   'Заказ создан'),
    ('paid',      'Заказ оплачен'),
    ('cancelled', 'Заказ отменён'),
    ('shipped',   'Заказ отправлен'),
    ('completed', 'Заказ завершён');

-- TODO: Создать таблицу users
-- Столбцы: id (UUID PK), email, name, created_at
-- Ограничения:
--   - email UNIQUE
--   - email NOT NULL и не пустой
--   - email валидный (regex через CHECK)
CREATE TABLE users (
    id         UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    email      VARCHAR(255)  NOT NULL UNIQUE,
    name       VARCHAR(255)  NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    CONSTRAINT email_not_empty CHECK (email <> ''),
    CONSTRAINT email_valid     CHECK (email ~* '^[a-zA-Z0-9_.+-]+@[a-zA-Z0-9-]+\.[a-zA-Z0-9-.]+$')
);

-- TODO: Создать таблицу orders
-- Столбцы: id (UUID PK), user_id (FK), status (FK), total_amount, created_at
-- Ограничения:
--   - user_id -> users(id)
--   - status -> order_statuses(status)
--   - total_amount >= 0
CREATE TABLE orders (
    id           UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id      UUID          NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    status       VARCHAR(20)   NOT NULL REFERENCES order_statuses(status),
    total_amount NUMERIC(12,2) NOT NULL DEFAULT 0,
    created_at   TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    CONSTRAINT total_amount_non_negative CHECK (total_amount >= 0)
);

-- TODO: Создать таблицу order_items
-- Столбцы: id (UUID PK), order_id (FK), product_name, price, quantity
-- Ограничения:
--   - order_id -> orders(id) CASCADE
--   - price >= 0
--   - quantity > 0
--   - product_name не пустой
CREATE TABLE order_items (
    id           UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    order_id     UUID          NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    product_name VARCHAR(255)  NOT NULL,
    price        NUMERIC(12,2) NOT NULL,
    quantity     INTEGER       NOT NULL,
    CONSTRAINT product_name_not_empty CHECK (product_name <> ''),
    CONSTRAINT price_non_negative     CHECK (price >= 0),
    CONSTRAINT quantity_positive      CHECK (quantity > 0)
);

-- TODO: Создать таблицу order_status_history
-- Столбцы: id (UUID PK), order_id (FK), status (FK), changed_at
-- Ограничения:
--   - order_id -> orders(id) CASCADE
--   - status -> order_statuses(status)
CREATE TABLE order_status_history (
    id         UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    order_id   UUID        NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    status     VARCHAR(20) NOT NULL REFERENCES order_statuses(status),
    changed_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================
-- КРИТИЧЕСКИЙ ИНВАРИАНТ: Нельзя оплатить заказ дважды
-- ============================================
-- TODO: Создать функцию триггера check_order_not_already_paid()
-- При изменении статуса на 'paid' проверить что его нет в истории
-- Если есть - RAISE EXCEPTION
CREATE OR REPLACE FUNCTION check_order_not_already_paid()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.status = 'paid' AND OLD.status <> 'paid' THEN
        IF EXISTS (
            SELECT 1 FROM order_status_history
            WHERE order_id = NEW.id AND status = 'paid'
        ) THEN
            RAISE EXCEPTION 'Order % has already been paid', NEW.id;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- TODO: Создать триггер trigger_check_order_not_already_paid
-- BEFORE UPDATE ON orders FOR EACH ROW
CREATE TRIGGER trigger_check_order_not_already_paid
BEFORE UPDATE ON orders
FOR EACH ROW
EXECUTE FUNCTION check_order_not_already_paid();

-- ============================================
-- БОНУС (опционально)
-- ============================================
-- TODO: Триггер автоматического пересчета total_amount
CREATE OR REPLACE FUNCTION recalculate_order_total()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE orders
    SET total_amount = (
        SELECT COALESCE(SUM(price * quantity), 0)
        FROM order_items
        WHERE order_id = COALESCE(NEW.order_id, OLD.order_id)
    )
    WHERE id = COALESCE(NEW.order_id, OLD.order_id);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_recalculate_order_total
AFTER INSERT OR UPDATE OR DELETE ON order_items
FOR EACH ROW
EXECUTE FUNCTION recalculate_order_total();

-- TODO: Триггер автоматической записи в историю при изменении статуса
CREATE OR REPLACE FUNCTION record_order_status_change()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO order_status_history (order_id, status, changed_at)
        VALUES (NEW.id, NEW.status, NOW());
    ELSIF TG_OP = 'UPDATE' AND OLD.status <> NEW.status THEN
        INSERT INTO order_status_history (order_id, status, changed_at)
        VALUES (NEW.id, NEW.status, NOW());
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- TODO: Триггер записи начального статуса при создании заказа
CREATE TRIGGER trigger_record_order_status_change
AFTER INSERT OR UPDATE ON orders
FOR EACH ROW
EXECUTE FUNCTION record_order_status_change();