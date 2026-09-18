pub mod commands;
pub mod connection_url;
pub mod drivers;
pub mod error;
pub mod models;
pub mod sql;
pub mod state;
pub mod storage;
pub mod tls;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_fs::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(tauri_plugin_process::init())
        .plugin(tauri_plugin_clipboard_manager::init())
        .manage(state::AppState::default())
        .invoke_handler(tauri::generate_handler![
            commands::list_profiles,
            commands::save_profile,
            commands::delete_profile,
            commands::parse_connection_url,
            commands::looks_like_connection_url,
            commands::connection_url_for_profile,
            commands::connect,
            commands::test_connection,
            commands::disconnect,
            commands::open_connection_ids,
            commands::execute_sql,
            commands::list_databases,
            commands::list_schemas,
            commands::list_tables,
            commands::describe_table,
            commands::create_statement,
            commands::use_database,
            commands::fetch_rows,
            commands::count_rows,
            commands::get_settings,
            commands::set_settings,
            commands::get_history,
            commands::add_history,
            commands::clear_history,
            commands::get_snippets,
            commands::set_snippets,
            commands::data_directory,
        ])
        .run(tauri::generate_context!())
        .expect("error while running MieSQL");
}
