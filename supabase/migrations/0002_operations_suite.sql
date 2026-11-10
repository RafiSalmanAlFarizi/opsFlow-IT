-- ============================================================================
-- OpsFlow IT — Compacted Migration 2/2: Operations Suite
-- ============================================================================
-- Compact equivalent of migrations (in chronological order):
--   20260517120000_create_it_schedules.sql
--   20260517130000_create_project_planning.sql
--   20260517150000_create_it_daily_logs.sql
--   20260520122300_add_l_status_to_schedules.sql
--   20260522124101_add_image_url_to_logs.sql
--   20260523002500_add_computer_and_infra_to_item_services.sql
--   20260525210500_add_parent_id_to_locations.sql
--   20260526113200_create_it_notes.sql
--   20260526115000_add_is_todo_to_notes.sql
--   20260526225500_add_destination_location_to_item_services.sql
--   20260526233000_add_attendance_details_to_schedules.sql
--   20260527000000_add_parent_id_to_categories.sql
--   20260531010000_delete_empty_item_stocks.sql
--
-- Catatan kronologi penting: tabel di bawah dibuat SETELAH REVOKE blanket
-- skema public untuk role anon di 0001, sehingga:
--   - it_schedules mempertahankan GRANT ALL ... TO anon yang eksplisit;
--   - fungsi delete_empty_item_stocks mempertahankan EXECUTE default PUBLIC
--     (tidak tersapu REVOKE 0001 karena dibuat setelahnya).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Jadwal Tim IT (status Check akhir sudah mencakup 'L'/Libur)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.it_schedules (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  member_name TEXT NOT NULL, -- e.g. 'Fikri', 'Raffa'
  schedule_date DATE NOT NULL, -- date of the schedule
  status TEXT NOT NULL CHECK (status IN ('M', 'C', 'DP', 'PH', 'L')), -- M=Masuk, C=Cuti, DP=Day Off/Extra, PH=Public Holiday, L=Libur
  notes TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),

  -- Detail Absensi (jam masuk, jam keluar, lembur)
  check_in_time TEXT,
  check_out_time TEXT,
  overtime_hours NUMERIC DEFAULT 0,
  overtime_notes TEXT,

  -- Cegah jadwal ganda untuk anggota yang sama pada tanggal yang sama
  CONSTRAINT unique_member_date UNIQUE (member_name, schedule_date)
);

GRANT ALL ON TABLE public.it_schedules TO anon, authenticated, service_role;

ALTER TABLE public.it_schedules ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Allow authenticated users full access on it_schedules" ON public.it_schedules;
CREATE POLICY "Allow authenticated users full access on it_schedules"
ON public.it_schedules FOR ALL
TO authenticated
USING (((SELECT auth.role()) = 'authenticated'))
WITH CHECK (((SELECT auth.role()) = 'authenticated'));

-- ---------------------------------------------------------------------------
-- Perencanaan Proyek IT + Logs Progres + RAB (Rencana Anggaran Biaya)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.it_projects (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    description TEXT,
    status TEXT NOT NULL DEFAULT 'Planning' CHECK (status IN ('Planning', 'In Progress', 'On Hold', 'Completed')),
    progress_percent INTEGER NOT NULL DEFAULT 0 CHECK (progress_percent >= 0 AND progress_percent <= 100),
    start_date DATE,
    target_date DATE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.it_project_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id UUID NOT NULL REFERENCES public.it_projects(id) ON DELETE CASCADE,
    log_date TIMESTAMPTZ NOT NULL DEFAULT now(),
    content TEXT NOT NULL,
    progress_percent_after INTEGER NOT NULL CHECK (progress_percent_after >= 0 AND progress_percent_after <= 100),
    image_url TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Rencana Anggaran Biaya terikat langsung pada proyek
CREATE TABLE IF NOT EXISTS public.it_project_rab (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id UUID NOT NULL REFERENCES public.it_projects(id) ON DELETE CASCADE,
    item_name TEXT NOT NULL,
    quantity NUMERIC NOT NULL DEFAULT 1 CHECK (quantity > 0),
    unit TEXT NOT NULL DEFAULT 'pcs',
    price_per_unit NUMERIC NOT NULL DEFAULT 0 CHECK (price_per_unit >= 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.it_projects ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.it_project_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.it_project_rab ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated users can select projects"
    ON public.it_projects FOR SELECT
    USING (((SELECT auth.role()) = 'authenticated'));

CREATE POLICY "Authenticated users can insert projects"
    ON public.it_projects FOR INSERT
    WITH CHECK (((SELECT auth.role()) = 'authenticated'));

CREATE POLICY "Authenticated users can update projects"
    ON public.it_projects FOR UPDATE
    USING (((SELECT auth.role()) = 'authenticated'));

CREATE POLICY "Authenticated users can delete projects"
    ON public.it_projects FOR DELETE
    USING (((SELECT auth.role()) = 'authenticated'));

CREATE POLICY "Authenticated users can select project logs"
    ON public.it_project_logs FOR SELECT
    USING (((SELECT auth.role()) = 'authenticated'));

CREATE POLICY "Authenticated users can insert project logs"
    ON public.it_project_logs FOR INSERT
    WITH CHECK (((SELECT auth.role()) = 'authenticated'));

CREATE POLICY "Authenticated users can update project logs"
    ON public.it_project_logs FOR UPDATE
    USING (((SELECT auth.role()) = 'authenticated'));

CREATE POLICY "Authenticated users can delete project logs"
    ON public.it_project_logs FOR DELETE
    USING (((SELECT auth.role()) = 'authenticated'));

CREATE POLICY "Authenticated users can select rab"
    ON public.it_project_rab FOR SELECT
    USING (((SELECT auth.role()) = 'authenticated'));

CREATE POLICY "Authenticated users can insert rab"
    ON public.it_project_rab FOR INSERT
    WITH CHECK (((SELECT auth.role()) = 'authenticated'));

CREATE POLICY "Authenticated users can update rab"
    ON public.it_project_rab FOR UPDATE
    USING (((SELECT auth.role()) = 'authenticated'));

CREATE POLICY "Authenticated users can delete rab"
    ON public.it_project_rab FOR DELETE
    USING (((SELECT auth.role()) = 'authenticated'));

-- Hybird File Storage: bucket dokumentasi proyek (publik)
INSERT INTO storage.buckets (id, name, public)
VALUES ('project-documentation', 'project-documentation', true)
ON CONFLICT (id) DO NOTHING;

CREATE POLICY "Public read access on project docs"
    ON storage.objects FOR SELECT
    USING (bucket_id = 'project-documentation');

CREATE POLICY "Authenticated write access on project docs"
    ON storage.objects FOR INSERT
    WITH CHECK (bucket_id = 'project-documentation' AND ((SELECT auth.role()) = 'authenticated'));

CREATE POLICY "Authenticated delete access on project docs"
    ON storage.objects FOR DELETE
    USING (bucket_id = 'project-documentation' AND ((SELECT auth.role()) = 'authenticated'));

-- ---------------------------------------------------------------------------
-- Laporan Kerja Harian (Laporan Harian)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.it_daily_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    date DATE NOT NULL DEFAULT CURRENT_DATE,
    activity_name TEXT NOT NULL,
    details TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'Selesai' CHECK (status IN ('Selesai', 'Pending', 'Terhambat')),
    image_url TEXT,
    technician_name TEXT NOT NULL DEFAULT 'Tim IT Support',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.it_daily_logs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated users can select daily logs"
    ON public.it_daily_logs FOR SELECT
    USING (((SELECT auth.role()) = 'authenticated'));

CREATE POLICY "Authenticated users can insert daily logs"
    ON public.it_daily_logs FOR INSERT
    WITH CHECK (((SELECT auth.role()) = 'authenticated'));

CREATE POLICY "Authenticated users can update daily logs"
    ON public.it_daily_logs FOR UPDATE
    USING (((SELECT auth.role()) = 'authenticated'));

CREATE POLICY "Authenticated users can delete daily logs"
    ON public.it_daily_logs FOR DELETE
    USING (((SELECT auth.role()) = 'authenticated'));

-- ---------------------------------------------------------------------------
-- Catatan IT (Notes)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.it_notes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title TEXT NOT NULL,
    content TEXT NOT NULL,
    color TEXT NOT NULL DEFAULT 'default',
    is_pinned BOOLEAN NOT NULL DEFAULT FALSE,
    is_todo BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.it_notes ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated users can select notes" ON public.it_notes FOR SELECT USING (((SELECT auth.role()) = 'authenticated'));
CREATE POLICY "Authenticated users can insert notes" ON public.it_notes FOR INSERT WITH CHECK (((SELECT auth.role()) = 'authenticated'));
CREATE POLICY "Authenticated users can update notes" ON public.it_notes FOR UPDATE USING (((SELECT auth.role()) = 'authenticated'));
CREATE POLICY "Authenticated users can delete notes" ON public.it_notes FOR DELETE USING (((SELECT auth.role()) = 'authenticated'));

-- ---------------------------------------------------------------------------
-- Pembersihan Stok Otomatis (hapus baris item_stocks saat quantity <= 0)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION delete_empty_item_stocks()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.quantity <= 0 THEN
    DELETE FROM item_stocks WHERE id = NEW.id;
    RETURN NULL;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS check_empty_item_stocks ON public.item_stocks;
CREATE TRIGGER check_empty_item_stocks
AFTER INSERT OR UPDATE OF quantity ON public.item_stocks
FOR EACH ROW
EXECUTE FUNCTION delete_empty_item_stocks();

-- ---------------------------------------------------------------------------
-- Muat ulang cache skema API PostgREST
-- ---------------------------------------------------------------------------
NOTIFY pgrst, 'reload schema';
