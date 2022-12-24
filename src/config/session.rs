use std::time::Duration;

use smtp_proto::*;

use super::{
    utils::{AsKey, ParseValue},
    *,
};

impl Config {
    pub fn parse_session_config(&self, ctx: &ConfigContext) -> super::Result<SessionConfig> {
        let available_keys = [
            EnvelopeKey::Listener,
            EnvelopeKey::RemoteIp,
            EnvelopeKey::LocalIp,
        ];

        Ok(SessionConfig {
            duration: self
                .parse_if_block("session.duration", ctx, &available_keys)?
                .unwrap_or_else(|| IfBlock::new(Duration::from_secs(15 * 60))),
            transfer_limit: self
                .parse_if_block("session.transfer-limit", ctx, &available_keys)?
                .unwrap_or_else(|| IfBlock::new(500 * 1024 * 1024)),
            timeout: self
                .parse_if_block::<Option<Duration>>("session.timeout", ctx, &available_keys)?
                .unwrap_or_else(|| IfBlock::new(Some(Duration::from_secs(5 * 60))))
                .try_unwrap("session.timeout")
                .unwrap_or_else(|_| IfBlock::new(Duration::from_secs(5 * 60))),
            connect: self.parse_session_connect(ctx)?,
            ehlo: self.parse_session_ehlo(ctx)?,
            auth: self.parse_session_auth(ctx)?,
            mail: self.parse_session_mail(ctx)?,
            rcpt: self.parse_session_rcpt(ctx)?,
            data: self.parse_session_data(ctx)?,
        })
    }

    fn parse_session_connect(&self, ctx: &ConfigContext) -> super::Result<Connect> {
        let available_keys = [
            EnvelopeKey::Listener,
            EnvelopeKey::RemoteIp,
            EnvelopeKey::LocalIp,
        ];
        Ok(Connect {
            script: self
                .parse_if_block::<Option<String>>("session.connect.script", ctx, &available_keys)?
                .unwrap_or_default()
                .map_if_block(&ctx.scripts, "session.connect.script", "script")?,
            throttle: self.parse_throttle(
                "session.connect.throttle",
                ctx,
                &available_keys,
                THROTTLE_LISTENER | THROTTLE_REMOTE_IP | THROTTLE_LOCAL_IP,
            )?,
        })
    }

    fn parse_session_ehlo(&self, ctx: &ConfigContext) -> super::Result<Ehlo> {
        let available_keys = [
            EnvelopeKey::Listener,
            EnvelopeKey::RemoteIp,
            EnvelopeKey::LocalIp,
        ];
        Ok(Ehlo {
            script: self
                .parse_if_block::<Option<String>>("session.ehlo.script", ctx, &available_keys)?
                .unwrap_or_default()
                .map_if_block(&ctx.scripts, "session.ehlo.script", "script")?,
            require: self
                .parse_if_block("session.ehlo.require", ctx, &available_keys)?
                .unwrap_or_else(|| IfBlock::new(true)),
            multiple: self
                .parse_if_block("session.ehlo.multiple", ctx, &available_keys)?
                .unwrap_or_else(|| IfBlock::new(true)),
            pipelining: self
                .parse_if_block("session.ehlo.capabilities.pipelining", ctx, &available_keys)?
                .unwrap_or_else(|| IfBlock::new(true)),
            chunking: self
                .parse_if_block("session.ehlo.capabilities.chunking", ctx, &available_keys)?
                .unwrap_or_else(|| IfBlock::new(true)),
            requiretls: self
                .parse_if_block("session.ehlo.capabilities.requiretls", ctx, &available_keys)?
                .unwrap_or_default(),
            no_soliciting: self
                .parse_if_block(
                    "session.ehlo.capabilities.no-soliciting",
                    ctx,
                    &available_keys,
                )?
                .unwrap_or_default(),
            future_release: self
                .parse_if_block(
                    "session.ehlo.capabilities.future-release",
                    ctx,
                    &available_keys,
                )?
                .unwrap_or_default(),
            deliver_by: self
                .parse_if_block("session.ehlo.capabilities.deliver-by", ctx, &available_keys)?
                .unwrap_or_default(),
            mt_priority: self
                .parse_if_block(
                    "session.ehlo.capabilities.mt-priority",
                    ctx,
                    &available_keys,
                )?
                .unwrap_or_default(),
            size: self
                .parse_if_block("session.ehlo.capabilities.size", ctx, &available_keys)?
                .unwrap_or_else(|| IfBlock::new(Some(25 * 1024 * 1024))),
        })
    }

    fn parse_session_auth(&self, ctx: &ConfigContext) -> super::Result<Auth> {
        let available_keys = [
            EnvelopeKey::Listener,
            EnvelopeKey::RemoteIp,
            EnvelopeKey::LocalIp,
            EnvelopeKey::HeloDomain,
        ];
        let mechanisms = self
            .parse_if_block::<Vec<Mechanism>>("session.auth.enable", ctx, &available_keys)?
            .unwrap_or_default();
        Ok(Auth {
            script: self
                .parse_if_block::<Option<String>>("session.auth.script", ctx, &available_keys)?
                .unwrap_or_default()
                .map_if_block(&ctx.scripts, "session.auth.script", "script")?,
            require: self
                .parse_if_block("session.auth.require", ctx, &available_keys)?
                .unwrap_or_default(),
            lookup: self
                .parse_if_block::<Option<String>>("session.auth.lookup", ctx, &available_keys)?
                .unwrap_or_default()
                .map_if_block(&ctx.lists, "session.auth.lookup", "lookup list")?,
            mechanisms: IfBlock {
                if_then: mechanisms
                    .if_then
                    .into_iter()
                    .map(|i| IfThen {
                        conditions: i.conditions,
                        then: i.then.into_iter().fold(0, |acc, m| acc | m.mechanism),
                    })
                    .collect(),
                default: mechanisms
                    .default
                    .into_iter()
                    .fold(0, |acc, m| acc | m.mechanism),
            },
            errors_max: self
                .parse_if_block("session.auth.errors.max", ctx, &available_keys)?
                .unwrap_or_else(|| IfBlock::new(3)),
            errors_wait: self
                .parse_if_block("session.auth.errors.wait", ctx, &available_keys)?
                .unwrap_or_else(|| IfBlock::new(Duration::from_secs(30))),
        })
    }

    fn parse_session_mail(&self, ctx: &ConfigContext) -> super::Result<Mail> {
        let available_keys = [
            EnvelopeKey::AuthenticatedAs,
            EnvelopeKey::Listener,
            EnvelopeKey::RemoteIp,
            EnvelopeKey::LocalIp,
            EnvelopeKey::HeloDomain,
        ];
        Ok(Mail {
            script: self
                .parse_if_block::<Option<String>>("session.mail.script", ctx, &available_keys)?
                .unwrap_or_default()
                .map_if_block(&ctx.scripts, "session.mail.script", "script")?,
            throttle: self.parse_throttle(
                "session.mail.throttle",
                ctx,
                &available_keys,
                THROTTLE_LISTENER
                    | THROTTLE_REMOTE_IP
                    | THROTTLE_LOCAL_IP
                    | THROTTLE_AUTH_AS
                    | THROTTLE_HELO_DOMAIN
                    | THROTTLE_SENDER
                    | THROTTLE_SENDER_DOMAIN,
            )?,
        })
    }

    fn parse_session_rcpt(&self, ctx: &ConfigContext) -> super::Result<Rcpt> {
        let available_keys = [
            EnvelopeKey::Sender,
            EnvelopeKey::SenderDomain,
            EnvelopeKey::AuthenticatedAs,
            EnvelopeKey::Listener,
            EnvelopeKey::RemoteIp,
            EnvelopeKey::LocalIp,
            EnvelopeKey::HeloDomain,
        ];
        Ok(Rcpt {
            script: self
                .parse_if_block::<Option<String>>("session.rcpt.script", ctx, &available_keys)?
                .unwrap_or_default()
                .map_if_block(&ctx.scripts, "session.rcpt.script", "script")?,
            relay: self
                .parse_if_block("session.rcpt.relay", ctx, &available_keys)?
                .unwrap_or_else(|| IfBlock::new(false)),
            expn: self
                .parse_if_block("session.rcpt.expn", ctx, &available_keys)?
                .unwrap_or_else(|| IfBlock::new(false)),
            vrfy: self
                .parse_if_block("session.rcpt.vrfy", ctx, &available_keys)?
                .unwrap_or_else(|| IfBlock::new(false)),
            lookup_domains: self
                .parse_if_block::<Option<String>>(
                    "session.rcpt.lookup.domains",
                    ctx,
                    &available_keys,
                )?
                .unwrap_or_default()
                .map_if_block(&ctx.lists, "session.rcpt.lookup.domains", "lookup list")?,
            lookup_addresses: self
                .parse_if_block::<Option<String>>(
                    "session.rcpt.lookup.addresses",
                    ctx,
                    &available_keys,
                )?
                .unwrap_or_default()
                .map_if_block(&ctx.lists, "session.rcpt.lookup.addresses", "lookup list")?,
            errors_max: self
                .parse_if_block("session.rcpt.errors.max", ctx, &available_keys)?
                .unwrap_or_else(|| IfBlock::new(10)),
            errors_wait: self
                .parse_if_block("session.rcpt.errors.wait", ctx, &available_keys)?
                .unwrap_or_else(|| IfBlock::new(Duration::from_secs(30))),
            max_recipients: self
                .parse_if_block("session.rcpt.max-recipients", ctx, &available_keys)?
                .unwrap_or_else(|| IfBlock::new(100)),
            throttle: self.parse_throttle(
                "session.rcpt.throttle",
                ctx,
                &available_keys,
                THROTTLE_LISTENER
                    | THROTTLE_REMOTE_IP
                    | THROTTLE_LOCAL_IP
                    | THROTTLE_AUTH_AS
                    | THROTTLE_HELO_DOMAIN
                    | THROTTLE_RCPT
                    | THROTTLE_RCPT_DOMAIN
                    | THROTTLE_SENDER
                    | THROTTLE_SENDER_DOMAIN,
            )?,
        })
    }

    fn parse_session_data(&self, ctx: &ConfigContext) -> super::Result<Data> {
        let available_keys = [
            EnvelopeKey::Sender,
            EnvelopeKey::SenderDomain,
            EnvelopeKey::AuthenticatedAs,
            EnvelopeKey::Listener,
            EnvelopeKey::RemoteIp,
            EnvelopeKey::LocalIp,
            EnvelopeKey::Priority,
            EnvelopeKey::HeloDomain,
        ];
        Ok(Data {
            script: self
                .parse_if_block::<Option<String>>("session.data.script", ctx, &available_keys)?
                .unwrap_or_default()
                .map_if_block(&ctx.scripts, "session.data.script", "script")?,
            max_messages: self
                .parse_if_block("session.data.limits.messages", ctx, &available_keys)?
                .unwrap_or_else(|| IfBlock::new(10)),
            max_message_size: self
                .parse_if_block("session.data.limits.size", ctx, &available_keys)?
                .unwrap_or_else(|| IfBlock::new(25 * 1024 * 1024)),
            max_received_headers: self
                .parse_if_block("session.data.limits.received-headers", ctx, &available_keys)?
                .unwrap_or_else(|| IfBlock::new(50)),
            max_mime_parts: self
                .parse_if_block("session.data.limits.mime-parts", ctx, &available_keys)?
                .unwrap_or_else(|| IfBlock::new(50)),
            max_nested_messages: self
                .parse_if_block("session.data.limits.nested-messages", ctx, &available_keys)?
                .unwrap_or_else(|| IfBlock::new(3)),
            add_received: self
                .parse_if_block("session.data.add-headers.received", ctx, &available_keys)?
                .unwrap_or_else(|| IfBlock::new(true)),
            add_received_spf: self
                .parse_if_block(
                    "session.data.add-headers.received-spf",
                    ctx,
                    &available_keys,
                )?
                .unwrap_or_else(|| IfBlock::new(true)),
            add_return_path: self
                .parse_if_block("session.data.add-headers.return-path", ctx, &available_keys)?
                .unwrap_or_else(|| IfBlock::new(true)),
            add_auth_results: self
                .parse_if_block(
                    "session.data.add-headers.auth-results",
                    ctx,
                    &available_keys,
                )?
                .unwrap_or_else(|| IfBlock::new(true)),
            add_message_id: self
                .parse_if_block("session.data.add-headers.message-id", ctx, &available_keys)?
                .unwrap_or_else(|| IfBlock::new(true)),
            add_date: self
                .parse_if_block("session.data.add-headers.date", ctx, &available_keys)?
                .unwrap_or_else(|| IfBlock::new(true)),
        })
    }
}

impl ParseValue for MtPriority {
    fn parse_value(key: impl AsKey, value: &str) -> super::Result<Self> {
        match value.to_ascii_lowercase().as_str() {
            "mixer" => Ok(MtPriority::Mixer),
            "stanag4406" => Ok(MtPriority::Stanag4406),
            "nsep" => Ok(MtPriority::Nsep),
            _ => Err(format!(
                "Invalid priority value {:?} for property {:?}.",
                value,
                key.as_key()
            )),
        }
    }
}

struct Mechanism {
    mechanism: u64,
}

impl ParseValue for Mechanism {
    fn parse_value(key: impl AsKey, value: &str) -> super::Result<Self> {
        Ok(Mechanism {
            mechanism: match value.to_ascii_uppercase().as_str() {
                "LOGIN" => AUTH_LOGIN,
                "PLAIN" => AUTH_PLAIN,
                "XOAUTH2" => AUTH_XOAUTH2,
                "OAUTHBEARER" => AUTH_OAUTHBEARER,
                /*"SCRAM-SHA-256-PLUS" => AUTH_SCRAM_SHA_256_PLUS,
                "SCRAM-SHA-256" => AUTH_SCRAM_SHA_256,
                "SCRAM-SHA-1-PLUS" => AUTH_SCRAM_SHA_1_PLUS,
                "SCRAM-SHA-1" => AUTH_SCRAM_SHA_1,
                "XOAUTH" => AUTH_XOAUTH,
                "9798-M-DSA-SHA1" => AUTH_9798_M_DSA_SHA1,
                "9798-M-ECDSA-SHA1" => AUTH_9798_M_ECDSA_SHA1,
                "9798-M-RSA-SHA1-ENC" => AUTH_9798_M_RSA_SHA1_ENC,
                "9798-U-DSA-SHA1" => AUTH_9798_U_DSA_SHA1,
                "9798-U-ECDSA-SHA1" => AUTH_9798_U_ECDSA_SHA1,
                "9798-U-RSA-SHA1-ENC" => AUTH_9798_U_RSA_SHA1_ENC,
                "EAP-AES128" => AUTH_EAP_AES128,
                "EAP-AES128-PLUS" => AUTH_EAP_AES128_PLUS,
                "ECDH-X25519-CHALLENGE" => AUTH_ECDH_X25519_CHALLENGE,
                "ECDSA-NIST256P-CHALLENGE" => AUTH_ECDSA_NIST256P_CHALLENGE,
                "EXTERNAL" => AUTH_EXTERNAL,
                "GS2-KRB5" => AUTH_GS2_KRB5,
                "GS2-KRB5-PLUS" => AUTH_GS2_KRB5_PLUS,
                "GSS-SPNEGO" => AUTH_GSS_SPNEGO,
                "GSSAPI" => AUTH_GSSAPI,
                "KERBEROS_V4" => AUTH_KERBEROS_V4,
                "KERBEROS_V5" => AUTH_KERBEROS_V5,
                "NMAS-SAMBA-AUTH" => AUTH_NMAS_SAMBA_AUTH,
                "NMAS_AUTHEN" => AUTH_NMAS_AUTHEN,
                "NMAS_LOGIN" => AUTH_NMAS_LOGIN,
                "NTLM" => AUTH_NTLM,
                "OAUTH10A" => AUTH_OAUTH10A,
                "OPENID20" => AUTH_OPENID20,
                "OTP" => AUTH_OTP,
                "SAML20" => AUTH_SAML20,
                "SECURID" => AUTH_SECURID,
                "SKEY" => AUTH_SKEY,
                "SPNEGO" => AUTH_SPNEGO,
                "SPNEGO-PLUS" => AUTH_SPNEGO_PLUS,
                "SXOVER-PLUS" => AUTH_SXOVER_PLUS,
                "CRAM-MD5" => AUTH_CRAM_MD5,
                "DIGEST-MD5" => AUTH_DIGEST_MD5,
                "ANONYMOUS" => AUTH_ANONYMOUS,*/
                _ => {
                    return Err(format!(
                        "Unsupported mechanism {:?} for property {:?}.",
                        value,
                        key.as_key()
                    ))
                }
            },
        })
    }
}
