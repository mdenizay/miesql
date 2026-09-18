//! TLS setup shared by the network drivers.
//!
//! rustls rather than the platform OpenSSL: that is the difference between a Linux build
//! that runs on any distro and one that needs `-dev` packages installed, and it removes
//! OpenSSL from the Windows build entirely.
//!
//! Certificates are **not** validated. That matches what `sslmode=require` means in libpq
//! and what `ssl-mode=REQUIRED` means in MySQL: encrypt the connection, but do not check
//! who is on the other end. Validation is `verify-ca`/`verify-full`, which MieSQL does not
//! implement yet and reports as downgraded rather than pretending to honour.

use crate::error::{DbError, DbResult};
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{ClientConfig, DigitallySignedStruct, SignatureScheme};
use std::sync::Arc;

#[derive(Debug)]
struct AcceptAnyServerCert;

impl ServerCertVerifier for AcceptAnyServerCert {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            dss,
            &provider().signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &provider().signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        provider()
            .signature_verification_algorithms
            .supported_schemes()
    }
}

/// Installs ring as the process-wide default.
///
/// rustls refuses to guess when more than one provider is compiled in, and the way it
/// refuses is a panic from inside whichever driver happens to open a connection first.
/// Naming the provider once at startup turns that into a decision rather than a crash.
pub fn ensure_crypto_provider() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        // An error here means something else installed one first, which is equally fine.
        let _ = rustls::crypto::ring::default_provider().install_default();
    });
}

fn provider() -> Arc<rustls::crypto::CryptoProvider> {
    Arc::new(rustls::crypto::ring::default_provider())
}

/// A client config that encrypts without validating the server certificate.
pub fn client_config() -> DbResult<Arc<ClientConfig>> {
    let config = ClientConfig::builder_with_provider(provider())
        .with_safe_default_protocol_versions()
        .map_err(|e| DbError::new(format!("Could not configure TLS: {e}")))?
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(AcceptAnyServerCert))
        .with_no_client_auth();
    Ok(Arc::new(config))
}

pub fn postgres_connector() -> DbResult<tokio_postgres_rustls::MakeRustlsConnect> {
    Ok(tokio_postgres_rustls::MakeRustlsConnect::new(
        (*client_config()?).clone(),
    ))
}
