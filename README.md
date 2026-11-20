# VTX Warehouse — web app quản lý container

## Xem demo
Mở `index.html` trong trình duyệt. Nếu chưa khai báo Supabase, ứng dụng tự chạy chế độ demo với dữ liệu mẫu lưu trong localStorage của thiết bị. Demo không đồng bộ giữa thiết bị.

## Deploy online
1. Tạo dự án tại supabase.com, mở SQL Editor và chạy toàn bộ `schema.sql`.
2. Trong Supabase → Project Settings → API (hoặc Connect), lấy Project URL và publishable/anon key. KHÔNG sử dụng service_role/secret key trong HTML.
3. Mở `index.html`, điền `SUPABASE_URL` và `SUPABASE_ANON_KEY` ở gần cuối file.
4. Trong Supabase → Authentication → Providers bật Email. Với môi trường thực tế, tắt đăng ký công khai hoặc kiểm soát nhân viên được cấp quyền.
5. Đẩy thư mục lên GitHub và import vào Vercel. Framework Preset: Other; build command: để trống; output directory: `.`. Hoặc deploy qua Vercel CLI.
6. Đăng nhập bằng tài khoản Supabase Auth; thêm bãi, cont, nhập/xuất hàng, chi phí.

## Lưu ý vận hành
Đây là MVP/demo. Quyền truy cập SQL hiện cho mọi người dùng authenticated, chỉ phù hợp nhóm thử nghiệm tin cậy. Để vận hành thật cần quản lý quyền nhân viên, log thay đổi, giao dịch xuất kho nguyên tử ở database (tránh hai nhân viên cùng xuất vượt tồn), sửa/xóa chứng từ, lịch sử thanh toán, đối soát công nợ, bảo mật ảnh và backup. Báo cáo tháng tính theo ngày chứng từ chi phí; tiền điện của khoản đang cắm tính đến hôm nay, chưa phân bổ chi phí điện theo từng tháng. Không dùng kết quả này làm sổ kế toán chính thức khi chưa hoàn thiện đối soát.


## Nâng cấp V3 — khối lượng theo kiện
- Nhập: số kiện × kg/kiện = tổng kg.
- Xuất: chọn bãi, cont, lô và số kiện; tự tính kg xuất, kiểm tra tồn và trừ cả kiện/kg.
- Tồn kho, sơ đồ cont, báo cáo CSV thể hiện kiện và kg.
- Supabase đã dùng V2: chạy `upgrade-v3.sql` trong SQL Editor trước khi thay `index.html`.
- Dữ liệu cũ chưa có kg/kiện sẽ tạm suy ra từ quantity/packages; phải rà soát lại vì trước đây quantity có thể không phải kg.
- V3 giả định các kiện của cùng một lô có cùng kg/kiện. Nếu mỗi kiện thực tế cân khác nhau, cần quản lý trọng lượng từng kiện riêng.

## V4 - Chuyển kho
Trong tab **Hàng hóa**, chọn **Chuyển kho**, chọn bãi/container nguồn, lô hàng, bãi/container đích, số kiện và ngày chuyển. Khối lượng = số kiện × kg/kiện. Hệ thống trừ tồn lô nguồn và tạo lô tại container đích, giữ nguyên tên hàng, khách hàng, container đầu vào và ảnh. Chuyển kho không tính là xuất bán/nhập mới trong báo cáo tổng nhập/xuất tháng; lịch sử có hai dòng Chuyển đi/Nhận chuyển.

Nếu đã kết nối Supabase, chạy `upgrade-v4.sql` trong SQL Editor **trước khi** deploy V4. Hàm `transfer_stock` chạy trong một transaction và khóa lô nguồn để chống chuyển vượt tồn giữa các yêu cầu chuyển đồng thời. Chức năng xuất kho thường ở các phiên bản hiện tại chưa dùng khóa transaction tương tự; cần nâng cấp trước khi vận hành nhiều người đồng thời.
