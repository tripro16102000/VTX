-- V15: màu riêng cho container đang chứa hàng, độc lập với màu cho thuê.
-- Chạy một lần trong Supabase SQL Editor trên database V14 hiện tại.
ALTER TABLE public.slots ADD COLUMN IF NOT EXISTS stock_color text;
ALTER TABLE public.slots DROP CONSTRAINT IF EXISTS slots_stock_color_valid;
ALTER TABLE public.slots ADD CONSTRAINT slots_stock_color_valid
 CHECK (stock_color IS NULL OR stock_color ~ '^#[0-9a-fA-F]{6}$');
-- Không thay đổi RLS hiện có, không cấp quyền cho anon.
