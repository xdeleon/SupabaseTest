import Foundation
import Supabase
import Auth

let supabase = SupabaseClient(
    supabaseURL: URL(string: "https://kmmbpjedcculmlblddet.supabase.co")!,
    supabaseKey: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImttbWJwamVkY2N1bG1sYmxkZGV0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjA5MDM0MjQsImV4cCI6MjA3NjQ3OTQyNH0.aujF6ehTk3yb24ujvi4WFLkUGn3j-GhEsZXuM8ybEpI",
    options: SupabaseClientOptions(
        auth: SupabaseClientOptions.AuthOptions(
            emitLocalSessionAsInitialSession: true
        )
    )
)
