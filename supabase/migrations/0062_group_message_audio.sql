-- ============================================================================
-- SOCIAL — Notas de voz en chats de grupo, comparado con WhatsApp/
-- Messenger/Telegram: última pieza del hueco explícitamente documentado
-- ("voz/read-receipts en chats de grupo") -- reacciones y "visto por" ya
-- se cerraron en las dos rondas anteriores (0060/0061).
--
-- Sin infraestructura nueva: `VoiceRecorder.kt`/`.swift`
-- (MediaRecorder/AVAudioRecorder nativos) y
-- `StorageUploader.uploadAudioFile()`/`.uploadAudio()` ya existen y son
-- 100% reutilizables tal cual, construidos para el chat 1:1 en
-- 0019_message_audio.sql -- esta migración solo replica el cambio de
-- esquema real de esa migración sobre `group_messages`.
-- ============================================================================

alter table group_messages add column if not exists audio_url text;

-- `check (body is not null or media_url is not null)` (0057_group_chats.sql)
-- se creó sin nombre explícito, así que Postgres le asignó el nombre
-- autogenerado real `group_messages_check` (primer check sin nombre de la
-- tabla) -- confirmado empíricamente en una reproducción mínima con
-- PGlite antes de escribir esta migración, mismo criterio de "verificar,
-- no asumir" ya aplicado al resto de la sesión.
alter table group_messages drop constraint if exists group_messages_check;
alter table group_messages add constraint group_messages_has_content
    check (body is not null or media_url is not null or audio_url is not null);
