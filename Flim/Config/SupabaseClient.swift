import Foundation
import Supabase

/// Production's project for the App Store app, FLIM Beta's own for the beta (`FlimEnvironment`).
let supabase = SupabaseClient(
    supabaseURL: FlimEnvironment.current.supabaseURL,
    supabaseKey: FlimEnvironment.current.supabaseKey
)
