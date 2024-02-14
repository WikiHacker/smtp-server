/*
 * Copyright (c) 2023 Stalwart Labs Ltd.
 *
 * This file is part of the Stalwart Mail Server.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as
 * published by the Free Software Foundation, either version 3 of
 * the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Affero General Public License for more details.
 * in the LICENSE file at the top-level directory of this distribution.
 * You should have received a copy of the GNU Affero General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * You can be released from the requirements of the AGPLv3 license by
 * purchasing a commercial license. Please contact licensing@stalw.art
 * for more details.
*/

use std::time::Duration;

use directory::core::config::ConfigDirectory;
use smtp::core::{SmtpAdminSessionManager, SmtpSessionManager, SMTP};
use store::config::ConfigStore;
use utils::{
    config::{Config, ServerProtocol},
    enable_tracing, wait_for_shutdown, UnwrapFailure,
};

#[cfg(not(target_env = "msvc"))]
use jemallocator::Jemalloc;

#[cfg(not(target_env = "msvc"))]
#[global_allocator]
static GLOBAL: Jemalloc = Jemalloc;

pub const IPC_CHANNEL_BUFFER: usize = 1024;

#[tokio::main]
async fn main() -> std::io::Result<()> {
    let mut config = Config::init();
    // Enable tracing
    let _tracer = enable_tracing(
        &config,
        &format!(
            "Starting Stalwart SMTP Server v{}...",
            env!("CARGO_PKG_VERSION"),
        ),
    )
    .failed("Failed to enable tracing");
    let servers = config.parse_servers().failed("Invalid configuration");

    // Bind ports and drop privileges
    servers.bind(&config);

    // Parse stores
    let stores = config.parse_stores().await.failed("Invalid configuration");
    let data_store = stores
        .get_store(&config, "storage.data")
        .failed("Invalid configuration");

    // Update configuration
    config.update(data_store.config_list("").await.failed("Storage error"));

    // Parse directories
    let directory = config
        .parse_directory(&stores, data_store)
        .await
        .failed("Invalid configuration");
    let schedulers = config
        .parse_purge_schedules(
            &stores,
            config.value("storage.data"),
            config.value("storage.blob"),
        )
        .await
        .failed("Invalid configuration");

    // Init servers
    let smtp = SMTP::init(&config, &servers, &stores, &directory)
        .await
        .failed("Invalid configuration file");

    // Spawn servers
    let (shutdown_tx, shutdown_rx) = servers.spawn(|server, shutdown_rx| {
        match &server.protocol {
            ServerProtocol::Smtp | ServerProtocol::Lmtp => {
                server.spawn(SmtpSessionManager::new(smtp.clone()), shutdown_rx)
            }
            ServerProtocol::Http => {
                server.spawn(SmtpAdminSessionManager::new(smtp.clone()), shutdown_rx);
            }
            ServerProtocol::Jmap => {
                tracing::debug!(
                    "Ignoring JMAP server listener, not supported by SMTP-only release."
                );
            }
            ServerProtocol::Imap => {
                tracing::debug!(
                    "Ignoring IMAP server listener, not supported by SMTP-only release."
                );
            }
            ServerProtocol::ManageSieve => {
                tracing::debug!(
                    "Ignoring ManageSieve server listener, not supported by SMTP-only release."
                );
            }
        };
    });

    // Spawn purge schedulers
    for scheduler in schedulers {
        scheduler.spawn(shutdown_rx.clone());
    }

    // Wait for shutdown signal
    wait_for_shutdown(&format!(
        "Shutting down Stalwart SMTP Server v{}...",
        env!("CARGO_PKG_VERSION")
    ))
    .await;

    // Stop services
    let _ = shutdown_tx.send(true);

    // Wait for services to finish
    tokio::time::sleep(Duration::from_secs(1)).await;

    Ok(())
}
