-- ============================================================================
-- OpsFlow IT — Compacted Migration 1/2: Core Schema
-- ============================================================================
-- Compact equivalent of migrations (in chronological order):
--   20260510161800_initial_schema.sql
--   20260511163600_add_rls_policies.sql
--   20260511164500_update_po_schema.sql
--   20260511170000_update_po_schema_v2.sql
--   20260511180000_create_po_view.sql
--   20260511190000_update_items_schema.sql
--   20260511200000_move_condition_to_stocks.sql
--   20260512000000_add_invoice_to_po.sql
--   20260512010000_create_company_profile.sql
--   20260512020000_setup_storage_buckets.sql
--   20260512030000_create_profiles.sql
--   20260512040000_create_item_services.sql
--   20260512050000_update_profiles_roles.sql
--   20260512060000_create_computers.sql
--   20260512070000_add_advanced_computer_fields.sql
--   20260512080000_create_infrastructure_assets.sql
--   20260517090000_create_infra_maintenance_logs.sql
--   20260517100000_create_computer_maintenance_logs.sql
--   20260517110000_fix_supabase_security_advisories.sql
--
-- All ALTER/UPDATE churn (column additions, policy rewrites, constraint
-- swaps, view recreation) has been collapsed into the final schema shape.
-- Column/constraint/policy names and privileges match the end state exactly.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE TYPE po_status AS ENUM ('Draft', 'Menunggu Persetujuan', 'Disetujui', 'Ditolak', 'Selesai');

-- ---------------------------------------------------------------------------
-- Tables (dependency order, final shape)
-- ---------------------------------------------------------------------------

-- Kategori Barang (with SKU code + parent for nested tree view)
CREATE TABLE IF NOT EXISTS public.categories (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name TEXT NOT NULL,
  description TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  code TEXT,
  parent_id UUID REFERENCES public.categories(id) ON DELETE SET NULL
);

-- Lokasi / Gudang (with parent for sub-location hierarchy)
CREATE TABLE IF NOT EXISTS public.locations (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name TEXT NOT NULL,
  address TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  parent_id UUID REFERENCES public.locations(id) ON DELETE SET NULL
);

-- Master Barang (condition column retained for compatibility; canonical
-- condition lives on item_stocks)
CREATE TABLE IF NOT EXISTS public.items (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  sku TEXT UNIQUE NOT NULL,
  name TEXT NOT NULL,
  description TEXT,
  category_id UUID REFERENCES public.categories(id) ON DELETE SET NULL,
  price DECIMAL(15, 2) DEFAULT 0,
  image_url TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  condition TEXT DEFAULT 'Baru',
  unit TEXT DEFAULT 'PCS',
  has_conversion BOOLEAN DEFAULT FALSE,
  conversion_unit TEXT,
  conversion_rate DECIMAL(10, 2) DEFAULT 1
);

-- Supplier / Vendor
CREATE TABLE IF NOT EXISTS public.suppliers (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name TEXT NOT NULL,
  contact_person TEXT,
  phone TEXT,
  email TEXT,
  address TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Profil Pengguna (public, keeps auth.users in sync via trigger below)
CREATE TABLE IF NOT EXISTS public.profiles (
  id UUID REFERENCES auth.users ON DELETE CASCADE PRIMARY KEY,
  email TEXT,
  full_name TEXT,
  avatar_url TEXT,
  updated_at TIMESTAMPTZ DEFAULT now(),
  role TEXT DEFAULT 'Staff'
);

-- Profil Perusahaan (single-row singleton)
CREATE TABLE IF NOT EXISTS public.company_profile (
  id INT PRIMARY KEY DEFAULT 1,
  name TEXT DEFAULT 'IT Inventory',
  address TEXT,
  phone TEXT,
  email TEXT,
  logo_url TEXT,
  updated_at TIMESTAMPTZ DEFAULT now(),
  CONSTRAINT one_row_only CHECK (id = 1)
);

-- Aset Komputer / PC (with enterprise-grade fields)
CREATE TABLE IF NOT EXISTS public.computers (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  asset_number TEXT UNIQUE NOT NULL,
  name TEXT NOT NULL, -- Nama Komputer / Hostname (Contoh: PC-FINANCE-01)
  location_id UUID REFERENCES public.locations(id) ON DELETE SET NULL,
  user_assigned TEXT, -- Nama staf atau penanggung jawab perangkat

  -- Spesifikasi Teknis
  ip_address TEXT,
  operating_system TEXT,
  processor TEXT,
  ram TEXT, -- Contoh: 16GB DDR4
  storage TEXT, -- Contoh: 512GB SSD NVMe

  -- Status & Pemeliharaan
  status TEXT DEFAULT 'Aktif', -- 'Aktif', 'Maintenance', 'Rusak', 'Pensiun'
  last_maintenance_date DATE,
  next_maintenance_date DATE,
  notes TEXT,

  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),

  -- Parameter tingkat enterprise
  mac_address TEXT,
  serial_number TEXT,
  purchase_date DATE,
  warranty_expiry_date DATE,
  remote_support_id TEXT
);

-- Aset Infrastruktur (CCTV, DVR, Portal Gate, AC/Pendingin, Lainnya)
CREATE TABLE IF NOT EXISTS public.infrastructure_assets (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  asset_number TEXT UNIQUE NOT NULL,
  name TEXT NOT NULL,
  category TEXT NOT NULL, -- 'CCTV', 'DVR', 'Gate/Portal', 'AC/Pendingin', 'Lainnya'
  location_id UUID REFERENCES public.locations(id) ON DELETE SET NULL,
  status TEXT DEFAULT 'Aktif', -- 'Aktif', 'Maintenance', 'Rusak', 'Nonaktif'
  ip_address TEXT,
  last_maintenance_date DATE,
  next_maintenance_date DATE,
  vendor_name TEXT,
  notes TEXT,
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- Surat Pesanan (Purchase Orders)
CREATE TABLE IF NOT EXISTS public.purchase_orders (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  po_number TEXT UNIQUE NOT NULL,
  supplier_id UUID REFERENCES public.suppliers(id) ON DELETE SET NULL,
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  status po_status DEFAULT 'Draft',
  total_amount DECIMAL(15, 2) DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  admin_fee DECIMAL(15, 2) DEFAULT 0,
  shipping_fee DECIMAL(15, 2) DEFAULT 0,
  discount_amount DECIMAL(15, 2) DEFAULT 0,
  payment_method TEXT,
  subtotal DECIMAL(15, 2) DEFAULT 0,
  notes TEXT,
  department TEXT,
  requested_by TEXT,
  location_id UUID REFERENCES public.locations(id),
  supplier_type TEXT DEFAULT 'Offline',
  invoice_url TEXT
);

-- Detail Barang dalam PO
CREATE TABLE IF NOT EXISTS public.po_items (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  po_id UUID REFERENCES public.purchase_orders(id) ON DELETE CASCADE,
  item_id UUID REFERENCES public.items(id) ON DELETE SET NULL,
  quantity INTEGER NOT NULL,
  unit_price DECIMAL(15, 2) NOT NULL,
  total_price DECIMAL(15, 2) GENERATED ALWAYS AS (quantity * unit_price) STORED,
  custom_item_name TEXT,
  item_link TEXT,
  unit TEXT DEFAULT 'PCS'
);

-- Stok Barang (Per Lokasi + Kondisi; unik berdasarkan item + lokasi + kondisi)
CREATE TABLE IF NOT EXISTS public.item_stocks (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  item_id UUID REFERENCES public.items(id) ON DELETE CASCADE,
  location_id UUID REFERENCES public.locations(id) ON DELETE CASCADE,
  quantity INTEGER DEFAULT 0,
  last_updated TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  condition TEXT DEFAULT 'Normal',
  CONSTRAINT item_stocks_item_loc_cond_unique UNIQUE (item_id, location_id, condition)
);

-- Riwayat Keluar Masuk Stok (user_id terhubung ke auth.users dan profiles)
CREATE TABLE IF NOT EXISTS public.inventory_logs (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  item_id UUID REFERENCES public.items(id) ON DELETE CASCADE,
  location_id UUID REFERENCES public.locations(id) ON DELETE SET NULL,
  user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  mutation_type TEXT NOT NULL, -- 'INBOUND' atau 'OUTBOUND'
  quantity INTEGER NOT NULL,
  notes TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  CONSTRAINT fk_inventory_logs_profiles FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE SET NULL
);

-- Riwayat Transfer Antar Gudang (dual FK: auth.users + profiles)
CREATE TABLE IF NOT EXISTS public.item_transfers (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  item_id UUID REFERENCES public.items(id) ON DELETE CASCADE,
  from_location_id UUID REFERENCES public.locations(id) ON DELETE SET NULL,
  to_location_id UUID REFERENCES public.locations(id) ON DELETE SET NULL,
  user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  quantity INTEGER NOT NULL,
  transfer_date TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  notes TEXT,
  CONSTRAINT fk_item_transfers_profiles FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE SET NULL
);

-- Riwayat Perbaikan / Maintenance Perangkat (barang, PC, atau infrastruktur)
CREATE TABLE IF NOT EXISTS public.item_services (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  service_number TEXT UNIQUE NOT NULL,
  item_id UUID REFERENCES public.items(id) ON DELETE CASCADE,
  location_id UUID REFERENCES public.locations(id) ON DELETE SET NULL, -- Lokasi pengambilan barang rusak
  supplier_id UUID REFERENCES public.suppliers(id) ON DELETE SET NULL, -- Vendor / tempat service
  quantity INTEGER NOT NULL DEFAULT 1,

  -- Keluhan dan Kondisi
  problem_description TEXT,
  initial_condition TEXT DEFAULT 'Rusak', -- Kondisi awal sebelum diservice
  final_condition TEXT, -- Kondisi akhir setelah diservice (misal: Normal)

  -- Data Pengiriman
  sent_date TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  sent_by_name TEXT, -- Nama kurir/ekspedisi/staf pengirim
  service_doc_url TEXT, -- Dokumen tanda terima perbaikan/surat jalan

  -- Status & Biaya
  status TEXT DEFAULT 'Proses Service', -- 'Proses Service', 'Selesai', 'Dibatalkan'
  cost DECIMAL(15, 2) DEFAULT 0,
  invoice_url TEXT, -- Bukti faktur/invoice setelah selesai

  -- Waktu Penyelesaian
  completed_date TIMESTAMP WITH TIME ZONE,
  notes TEXT, -- Catatan teknisi/hasil perbaikan

  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),

  -- Perangkat yang diservis dapat berupa PC atau Aset Infrastruktur langsung
  computer_id UUID REFERENCES public.computers(id) ON DELETE SET NULL,
  infrastructure_asset_id UUID REFERENCES public.infrastructure_assets(id) ON DELETE SET NULL,
  destination_location_id UUID REFERENCES public.locations(id) ON DELETE SET NULL -- Lokasi tujuan setelah service selesai
);

-- Riwayat Perawatan Infrastruktur
CREATE TABLE IF NOT EXISTS public.infrastructure_maintenance_logs (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  asset_id UUID NOT NULL REFERENCES public.infrastructure_assets(id) ON DELETE CASCADE,
  maintenance_date DATE NOT NULL,
  maintenance_title TEXT NOT NULL, -- e.g. 'Maintenance 1', 'Maintenance 2'
  notes TEXT,
  performed_by TEXT,
  status_after TEXT DEFAULT 'Aktif',
  created_at TIMESTAMPTZ DEFAULT now(),
  image_url TEXT -- Bukti dokumentasi perawatan
);

-- Riwayat Perawatan Komputer
CREATE TABLE IF NOT EXISTS public.computer_maintenance_logs (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  computer_id UUID NOT NULL REFERENCES public.computers(id) ON DELETE CASCADE,
  maintenance_date DATE NOT NULL,
  maintenance_title TEXT NOT NULL, -- e.g. 'Maintenance 1', 'Maintenance 2'
  notes TEXT,
  performed_by TEXT,
  status_after TEXT DEFAULT 'Aktif',
  created_at TIMESTAMPTZ DEFAULT now(),
  image_url TEXT -- Bukti dokumentasi perawatan
);

-- ---------------------------------------------------------------------------
-- Row Level Security (aktif di seluruh tabel) + Kebijakan Akses Final
-- Ambil dari hasil optimasi kebijakan oleh fix_supabase_security_advisories:
-- pola subquery (SELECT auth.role()) [(SELECT auth.uid()) untuk profiles]
-- agar perencana kueri men-cache user ID/persen.
-- ---------------------------------------------------------------------------

ALTER TABLE public.categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.locations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.item_stocks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.item_transfers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.suppliers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.po_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.company_profile ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.computers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.infrastructure_assets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.infrastructure_maintenance_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.computer_maintenance_logs ENABLE ROW LEVEL SECURITY;

-- Catatan kronologi: item_services tetap dengan RLS NONAKTIF (dinonaktifkan
-- secara eksplisit saat dibuat dan tidak pernah diaktifkan kembali oleh
-- fix_supabase_security_advisories); kebijakannya tetap didefinisikan.

-- Inventaris Inti: akses penuh untuk pengguna terautentikasi
CREATE POLICY "Enable all for authenticated users" ON public.categories          FOR ALL TO authenticated USING (((SELECT auth.role()) = 'authenticated')) WITH CHECK (((SELECT auth.role()) = 'authenticated'));
CREATE POLICY "Enable all for authenticated users" ON public.locations           FOR ALL TO authenticated USING (((SELECT auth.role()) = 'authenticated')) WITH CHECK (((SELECT auth.role()) = 'authenticated'));
CREATE POLICY "Enable all for authenticated users" ON public.items               FOR ALL TO authenticated USING (((SELECT auth.role()) = 'authenticated')) WITH CHECK (((SELECT auth.role()) = 'authenticated'));
CREATE POLICY "Enable all for authenticated users" ON public.item_stocks         FOR ALL TO authenticated USING (((SELECT auth.role()) = 'authenticated')) WITH CHECK (((SELECT auth.role()) = 'authenticated'));
CREATE POLICY "Enable all for authenticated users" ON public.inventory_logs      FOR ALL TO authenticated USING (((SELECT auth.role()) = 'authenticated')) WITH CHECK (((SELECT auth.role()) = 'authenticated'));
CREATE POLICY "Enable all for authenticated users" ON public.item_transfers      FOR ALL TO authenticated USING (((SELECT auth.role()) = 'authenticated')) WITH CHECK (((SELECT auth.role()) = 'authenticated'));
CREATE POLICY "Enable all for authenticated users" ON public.suppliers           FOR ALL TO authenticated USING (((SELECT auth.role()) = 'authenticated')) WITH CHECK (((SELECT auth.role()) = 'authenticated'));
CREATE POLICY "Enable all for authenticated users" ON public.purchase_orders     FOR ALL TO authenticated USING (((SELECT auth.role()) = 'authenticated')) WITH CHECK (((SELECT auth.role()) = 'authenticated'));
CREATE POLICY "Enable all for authenticated users" ON public.po_items            FOR ALL TO authenticated USING (((SELECT auth.role()) = 'authenticated')) WITH CHECK (((SELECT auth.role()) = 'authenticated'));

-- Profil Perusahaan: baca untuk terautentikasi; tulis/ubah terautentikasi
CREATE POLICY "Allow authenticated users to read company profile"
ON public.company_profile FOR SELECT
TO authenticated
USING (true);

CREATE POLICY "Allow authenticated users to insert company profile"
ON public.company_profile FOR INSERT
TO authenticated
WITH CHECK (((SELECT auth.role()) = 'authenticated'));

CREATE POLICY "Allow authenticated users to update company profile"
ON public.company_profile FOR UPDATE
TO authenticated
USING (((SELECT auth.role()) = 'authenticated'))
WITH CHECK (((SELECT auth.role()) = 'authenticated'));

-- Profil Pengguna: publik dapat melihat; pengguna mengelola profil sendiri
CREATE POLICY "Public profiles are viewable by everyone."
  ON public.profiles FOR SELECT
  USING ( true );

CREATE POLICY "Users can insert their own profile."
  ON public.profiles FOR INSERT
  WITH CHECK ( (SELECT auth.uid()) = id );

CREATE POLICY "Users can update own profile."
  ON public.profiles FOR UPDATE
  USING ( (SELECT auth.uid()) = id );

-- Komputer: akses penuh terautentikasi
CREATE POLICY "Allow authenticated users full access on computers"
ON public.computers FOR ALL
TO authenticated
USING (((SELECT auth.role()) = 'authenticated'))
WITH CHECK (((SELECT auth.role()) = 'authenticated'));

-- Riwayat servis item: akses penuh terautentikasi
CREATE POLICY "Allow authenticated users full access on item_services"
ON public.item_services FOR ALL
TO authenticated
USING (((SELECT auth.role()) = 'authenticated'))
WITH CHECK (((SELECT auth.role()) = 'authenticated'));

--Infrastruktur, PC & log pemeliharaan: baca publik, tulis/ubah/hapus terautentikasi
CREATE POLICY "Allow public read access"  ON public.infrastructure_assets          FOR SELECT USING (true);
CREATE POLICY "Allow public insert access" ON public.infrastructure_assets          FOR INSERT TO authenticated WITH CHECK (((SELECT auth.role()) = 'authenticated'));
CREATE POLICY "Allow public update access" ON public.infrastructure_assets          FOR UPDATE TO authenticated USING (((SELECT auth.role()) = 'authenticated')) WITH CHECK (((SELECT auth.role()) = 'authenticated'));
CREATE POLICY "Allow public delete access" ON public.infrastructure_assets          FOR DELETE TO authenticated USING (((SELECT auth.role()) = 'authenticated'));

CREATE POLICY "Allow public read access"  ON public.infrastructure_maintenance_logs FOR SELECT USING (true);
CREATE POLICY "Allow public insert access" ON public.infrastructure_maintenance_logs FOR INSERT TO authenticated WITH CHECK (((SELECT auth.role()) = 'authenticated'));
CREATE POLICY "Allow public update access" ON public.infrastructure_maintenance_logs FOR UPDATE TO authenticated USING (((SELECT auth.role()) = 'authenticated')) WITH CHECK (((SELECT auth.role()) = 'authenticated'));
CREATE POLICY "Allow public delete access" ON public.infrastructure_maintenance_logs FOR DELETE TO authenticated USING (((SELECT auth.role()) = 'authenticated'));

CREATE POLICY "Allow public read access"  ON public.computer_maintenance_logs       FOR SELECT USING (true);
CREATE POLICY "Allow public insert access" ON public.computer_maintenance_logs       FOR INSERT TO authenticated WITH CHECK (((SELECT auth.role()) = 'authenticated'));
CREATE POLICY "Allow public update access" ON public.computer_maintenance_logs       FOR UPDATE TO authenticated USING (((SELECT auth.role()) = 'authenticated')) WITH CHECK (((SELECT auth.role()) = 'authenticated'));
CREATE POLICY "Allow public delete access" ON public.computer_maintenance_logs       FOR DELETE TO authenticated USING (((SELECT auth.role()) = 'authenticated'));

-- ---------------------------------------------------------------------------
-- View PO (security_invoker agar mengikuti RLS tabel dasarnya)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.purchase_orders_view
WITH (security_invoker = true) AS
SELECT
    po.*,
    s.name AS supplier_name,
    l.name AS location_name
FROM public.purchase_orders po
LEFT JOIN public.suppliers s ON po.supplier_id = s.id
LEFT JOIN public.locations l ON po.location_id = l.id;

-- ---------------------------------------------------------------------------
-- Seed Data Awal
-- ---------------------------------------------------------------------------

INSERT INTO public.company_profile (id, name)
VALUES (1, 'IT Inventory System')
ON CONFLICT (id) DO NOTHING;

-- Isi profil untuk pengguna yang sudah ada
INSERT INTO public.profiles (id, email)
SELECT id, email FROM auth.users
ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Trigger Registrasi Pengguna Baru (SECURITY DEFINER, search path tetap)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.profiles (id, email, full_name)
  VALUES (new.id, new.email, new.raw_user_meta_data->>'full_name');
  RETURN new;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- ---------------------------------------------------------------------------
-- Penyimpanan: bucket 'invoices' (privat — berisi dokumen pembelian sensitif)
-- ---------------------------------------------------------------------------
INSERT INTO storage.buckets (id, name, public)
VALUES ('invoices', 'invoices', false)
ON CONFLICT (id) DO NOTHING;

CREATE POLICY "Public Access"
ON storage.objects FOR SELECT
TO authenticated
USING ( bucket_id = 'invoices' );

CREATE POLICY "Authenticated Upload"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK ( bucket_id = 'invoices' );

CREATE POLICY "Authenticated Update"
ON storage.objects FOR UPDATE
TO authenticated
USING ( bucket_id = 'invoices' );

CREATE POLICY "Authenticated Delete"
ON storage.objects FOR DELETE
TO authenticated
USING ( bucket_id = 'invoices' );

-- ---------------------------------------------------------------------------
-- Privilese Tabel Akhir + Penguncian (Lockdown)
-- (hak akses anon dikukuhkan hilang; cf. chronology: diberikan sebelum
--  REVOKE blanket pada fix_supabase_security_advisories, akhir net sama)
-- ---------------------------------------------------------------------------
GRANT ALL ON TABLE public.item_services TO authenticated, service_role;
GRANT ALL ON TABLE public.profiles TO authenticated, service_role;
GRANT ALL ON TABLE public.computers TO authenticated, service_role;
GRANT ALL ON TABLE public.infrastructure_assets TO authenticated, service_role;
GRANT ALL ON TABLE public.infrastructure_maintenance_logs TO authenticated, service_role;
GRANT ALL ON TABLE public.computer_maintenance_logs TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION public.handle_new_user() FROM PUBLIC, authenticated, anon;

REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM anon;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon;
