-- Chạy toàn bộ trong Supabase SQL Editor.
create extension if not exists pgcrypto;
create table if not exists yards(id uuid primary key, name text not null);
create table if not exists slots(id uuid primary key, yard_id uuid not null references yards(id), name text not null, x numeric not null default 0, y numeric not null default 0);
create table if not exists lots(id uuid primary key, source_cont text not null, slot_id uuid not null references slots(id), product text not null, customer text not null, packages numeric not null check(packages>0), quantity numeric not null check(quantity>0), unit text not null default 'kiện', entry_date date not null, image_url text);
create table if not exists moves(id uuid primary key, lot_id uuid not null references lots(id), kind text not null check(kind in ('IN','OUT')), qty numeric not null check(qty>0), packages numeric check(packages>0), date date not null);
-- Tương thích với database đã tạo từ phiên bản trước.
alter table moves add column if not exists packages numeric check(packages>0);
create table if not exists costs(id uuid primary key, lot_id uuid not null references lots(id), handling numeric not null default 0, transport numeric not null default 0, extra numeric not null default 0, electric_start date, electric_end date, electric_daily numeric not null default 0, paid numeric not null default 0, date date not null);
-- Demo nội bộ: mọi tài khoản đã đăng nhập đều xem/sửa chung dữ liệu.
-- Trước khi dùng thực tế, cần thêm bảng nhân viên, phân quyền theo bãi, chính sách kiểm soát quyền ghi và audit log.
do $$ declare t text; begin foreach t in array array['yards','slots','lots','moves','costs'] loop
 execute format('alter table public.%I enable row level security',t);
 execute format('drop policy if exists "authenticated staff" on public.%I',t);
 execute format('create policy "authenticated staff" on public.%I for all to authenticated using (true) with check (true)',t);
end loop; end $$;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('goods','goods',true,10485760,array['image/jpeg','image/png','image/webp']) on conflict(id) do nothing;
drop policy if exists "staff uploads goods" on storage.objects;
create policy "staff uploads goods" on storage.objects for insert to authenticated with check(bucket_id='goods');
-- Chạy một lần trong Supabase SQL Editor nếu đã triển khai phiên bản cũ.
alter table public.moves add column if not exists packages numeric check (packages > 0);
-- Giao dịch cũ không có packages: giao diện ước tính theo tỷ lệ số lượng của lô.
-- Chạy trong Supabase SQL Editor khi nâng cấp lên V3.
alter table public.lots add column if not exists kg_per_package numeric;
-- Dữ liệu cũ không có kg/kiện: tự suy ra từ số lượng / số kiện, cần kiểm tra lại.
update public.lots set kg_per_package = quantity / nullif(packages,0) where kg_per_package is null;
-- Với lô hàng cũ, kiểm tra lại số lượng đang lưu có thực sự là kg hay không trước khi dùng báo cáo.
-- Chạy sau schema.sql, upgrade.sql và upgrade-v3.sql.
ALTER TABLE public.moves DROP CONSTRAINT IF EXISTS moves_kind_check;
ALTER TABLE public.moves ADD CONSTRAINT moves_kind_check CHECK (kind IN ('IN','OUT','TRANSFER_OUT','TRANSFER_IN'));
ALTER TABLE public.moves ADD COLUMN IF NOT EXISTS from_slot_id uuid REFERENCES public.slots(id);
ALTER TABLE public.moves ADD COLUMN IF NOT EXISTS to_slot_id uuid REFERENCES public.slots(id);

-- Chuyển kho trong 1 transaction, khóa lô nguồn để ngăn chuyển vượt tồn khi nhiều người cùng thao tác.
CREATE OR REPLACE FUNCTION public.transfer_stock(
 p_lot_id uuid, p_target_slot_id uuid, p_packages numeric, p_transfer_date date, p_new_lot_id uuid
) RETURNS void LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE src public.lots%ROWTYPE; target_exists boolean; current_packages numeric; current_kg numeric; unit_kg numeric; transfer_kg numeric;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Yêu cầu đăng nhập'; END IF;
 SELECT * INTO src FROM public.lots WHERE id=p_lot_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Không tìm thấy lô nguồn'; END IF;
 SELECT EXISTS(SELECT 1 FROM public.slots WHERE id=p_target_slot_id) INTO target_exists;
 IF NOT target_exists OR src.slot_id=p_target_slot_id THEN RAISE EXCEPTION 'Container đích không hợp lệ'; END IF;
 IF p_packages IS NULL OR p_packages<=0 OR p_packages<>trunc(p_packages) THEN RAISE EXCEPTION 'Số kiện phải là số nguyên dương'; END IF;
 IF p_transfer_date IS NULL THEN RAISE EXCEPTION 'Thiếu ngày chuyển'; END IF;
 unit_kg := COALESCE(src.kg_per_package,src.quantity/nullif(src.packages,0));
 IF unit_kg IS NULL OR unit_kg<=0 THEN RAISE EXCEPTION 'Khối lượng mỗi kiện không hợp lệ'; END IF;
 SELECT COALESCE(sum(CASE WHEN kind IN ('IN','TRANSFER_IN') THEN COALESCE(packages,qty/unit_kg) ELSE -COALESCE(packages,qty/unit_kg) END),0),
 COALESCE(sum(CASE WHEN kind IN ('IN','TRANSFER_IN') THEN qty ELSE -qty END),0)
 INTO current_packages,current_kg FROM public.moves WHERE lot_id=p_lot_id;
 transfer_kg:=p_packages*unit_kg;
 IF current_packages<p_packages OR current_kg+0.00001<transfer_kg THEN RAISE EXCEPTION 'Không đủ tồn kho để chuyển'; END IF;
 INSERT INTO public.lots(id,source_cont,slot_id,product,customer,packages,quantity,kg_per_package,unit,entry_date,image_url)
 VALUES(p_new_lot_id,src.source_cont,p_target_slot_id,src.product,src.customer,p_packages,transfer_kg,unit_kg,src.unit,p_transfer_date,src.image_url);
 INSERT INTO public.moves(id,lot_id,kind,qty,packages,date,from_slot_id,to_slot_id)
 VALUES(gen_random_uuid(),p_lot_id,'TRANSFER_OUT',transfer_kg,p_packages,p_transfer_date,src.slot_id,p_target_slot_id),
       (gen_random_uuid(),p_new_lot_id,'TRANSFER_IN',transfer_kg,p_packages,p_transfer_date,src.slot_id,p_target_slot_id);
END $$;
GRANT EXECUTE ON FUNCTION public.transfer_stock(uuid,uuid,numeric,date,uuid) TO authenticated;
-- V5: Công nợ độc lập với nhập hàng, không thay đổi/xóa dữ liệu costs cũ.
CREATE TABLE IF NOT EXISTS public.debts (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 customer text NOT NULL CHECK (length(trim(customer)) > 0),
 date date NOT NULL,
 handling numeric NOT NULL DEFAULT 0 CHECK (handling >= 0),
 transport numeric NOT NULL DEFAULT 0 CHECK (transport >= 0),
 extra numeric NOT NULL DEFAULT 0 CHECK (extra >= 0),
 container_name text NOT NULL DEFAULT '',
 rental_days integer NOT NULL DEFAULT 0 CHECK (rental_days >= 0),
 rental_daily numeric NOT NULL DEFAULT 0 CHECK (rental_daily >= 0),
 paid numeric NOT NULL DEFAULT 0 CHECK (paid >= 0),
 CONSTRAINT debt_paid_limit CHECK (paid <= handling + transport + extra + rental_days * rental_daily),
 CONSTRAINT rental_container_required CHECK (rental_days = 0 OR length(trim(container_name)) > 0)
);
ALTER TABLE public.debts ENABLE ROW LEVEL SECURITY;
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.debts TO authenticated;
DROP POLICY IF EXISTS "authenticated staff" ON public.debts;
CREATE POLICY "authenticated staff" ON public.debts FOR ALL TO authenticated USING (true) WITH CHECK (true);
-- Chỉ phù hợp với tài khoản nhân viên đáng tin cậy. Hãy bổ sung phân quyền trước khi vận hành thật.
-- V6: Bổ sung ngày bắt đầu thuê / ngày trả; không xóa công nợ cũ.
ALTER TABLE public.debts ADD COLUMN IF NOT EXISTS rental_start date;
ALTER TABLE public.debts ADD COLUMN IF NOT EXISTS rental_end date;
ALTER TABLE public.debts DROP CONSTRAINT IF EXISTS rental_dates_order;
ALTER TABLE public.debts ADD CONSTRAINT rental_dates_order CHECK (
  (rental_start IS NULL AND rental_end IS NULL) OR
  (rental_start IS NOT NULL AND rental_end IS NOT NULL AND rental_end >= rental_start)
);
-- Database tự tính lại số ngày, không tin vào giá trị do trình duyệt gửi lên.
CREATE OR REPLACE FUNCTION public.debts_set_rental_days() RETURNS trigger
LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF NEW.rental_start IS NOT NULL AND NEW.rental_end IS NOT NULL THEN
    IF NEW.rental_end < NEW.rental_start THEN
      RAISE EXCEPTION 'Ngày trả không được trước ngày bắt đầu thuê';
    END IF;
    NEW.rental_days := GREATEST(1, NEW.rental_end - NEW.rental_start);
  ELSIF NEW.rental_start IS NOT NULL OR NEW.rental_end IS NOT NULL THEN
    RAISE EXCEPTION 'Phải nhập đủ hai ngày thuê và trả';
  END IF;
  RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS debts_calculate_rental_days ON public.debts;
CREATE TRIGGER debts_calculate_rental_days
BEFORE INSERT OR UPDATE ON public.debts
FOR EACH ROW EXECUTE FUNCTION public.debts_set_rental_days();
-- Các khoản V5 cũ chưa có ngày thuê vẫn giữ số ngày đã lưu để đối soát.
-- Chạy SAU upgrade-v6.sql. Không xóa dữ liệu cũ.
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.yards, public.slots, public.lots, public.moves, public.debts TO authenticated;

-- Xóa lô chưa từng xuất/chuyển, đồng thời xóa phiếu nhập trong một transaction.
CREATE OR REPLACE FUNCTION public.delete_unused_lot(p_lot_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
BEGIN
  PERFORM 1 FROM public.lots WHERE id=p_lot_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Không tìm thấy lô hàng'; END IF;
  IF EXISTS (SELECT 1 FROM public.moves WHERE lot_id=p_lot_id AND kind <> 'IN') THEN
    RAISE EXCEPTION 'Không thể xóa lô đã xuất/chuyển';
  END IF;
  IF EXISTS (SELECT 1 FROM public.costs WHERE lot_id=p_lot_id) THEN
    RAISE EXCEPTION 'Lô có chi phí liên kết, không thể xóa';
  END IF;
  DELETE FROM public.moves WHERE lot_id=p_lot_id;
  DELETE FROM public.lots WHERE id=p_lot_id;
END; $$;

-- Sửa số kiện và kg/kiện của lô chưa xuất/chuyển; đồng bộ phiếu nhập.
CREATE OR REPLACE FUNCTION public.update_unused_lot(
  p_lot_id uuid, p_source_cont text, p_slot_id uuid, p_product text,
  p_customer text, p_packages numeric, p_kg_per_package numeric,
  p_entry_date date, p_image_url text
) RETURNS void LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
BEGIN
  PERFORM 1 FROM public.lots WHERE id=p_lot_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Không tìm thấy lô hàng'; END IF;
  IF EXISTS (SELECT 1 FROM public.moves WHERE lot_id=p_lot_id AND kind <> 'IN') THEN
    RAISE EXCEPTION 'Lô đã xuất/chuyển, không được sửa số kiện và khối lượng';
  END IF;
  IF p_packages <= 0 OR p_packages <> trunc(p_packages) OR p_kg_per_package <= 0 THEN
    RAISE EXCEPTION 'Số kiện hoặc kg/kiện không hợp lệ';
  END IF;
  UPDATE public.lots SET source_cont=p_source_cont,slot_id=p_slot_id,
    product=p_product,customer=p_customer,packages=p_packages,
    kg_per_package=p_kg_per_package,quantity=p_packages*p_kg_per_package,
    entry_date=p_entry_date,image_url=p_image_url
  WHERE id=p_lot_id;
  UPDATE public.moves SET packages=p_packages,qty=p_packages*p_kg_per_package,date=p_entry_date
  WHERE lot_id=p_lot_id AND kind='IN';
END; $$;
REVOKE ALL ON FUNCTION public.delete_unused_lot(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.update_unused_lot(uuid,text,uuid,text,text,numeric,numeric,date,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_unused_lot(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_unused_lot(uuid,text,uuid,text,text,numeric,numeric,date,text) TO authenticated;
