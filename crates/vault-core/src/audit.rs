//! Local-only password health audit. Nothing leaves the device.
//!
//! Over live (not trashed) items that have a non-empty password:
//! - reused: the exact same password is used by two or more items;
//! - weak: strength score below 3 (see `strength`);
//! - old: the current password was set more than 365 days ago.
//!
//! The password "set" time is the modified_at of the oldest consecutive
//! state (current, then history newest to oldest) that still holds the same
//! password; if every recorded state holds it, the item's created_at.
//!
//! security_score = round(100 * items_without_issues / items_with_password),
//! or 100 when no item has a password.

use std::collections::HashMap;

use vtf_core::{ItemData, Revision};

use crate::strength;

pub const OLD_AFTER_SECS: i64 = 365 * 24 * 60 * 60;

pub struct AuditItem<'a> {
    pub id: &'a str,
    pub data: &'a ItemData,
    pub created_at: i64,
    pub modified_at: i64,
    pub history: &'a [Revision],
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HealthReport {
    pub security_score: u8,
    pub reused_item_ids: Vec<String>,
    pub weak_item_ids: Vec<String>,
    pub old_item_ids: Vec<String>,
}

fn password_set_at(it: &AuditItem<'_>, pw: &str) -> i64 {
    let mut at = it.modified_at;
    for rev in it.history.iter().rev() {
        if rev.data.password.as_deref() == Some(pw) {
            at = rev.modified_at as i64;
        } else {
            return at;
        }
    }
    at.min(it.created_at)
}

pub fn health(items: &[AuditItem<'_>], now: i64) -> HealthReport {
    let with_pw: Vec<(&AuditItem<'_>, &str)> = items
        .iter()
        .filter_map(|it| it.data.password.as_deref().filter(|p| !p.is_empty()).map(|p| (it, p)))
        .collect();
    let mut by_pw: HashMap<&str, usize> = HashMap::new();
    for (_, p) in &with_pw {
        *by_pw.entry(p).or_default() += 1;
    }
    let mut r = HealthReport { security_score: 100, reused_item_ids: vec![], weak_item_ids: vec![], old_item_ids: vec![] };
    let mut clean = 0usize;
    for (it, p) in &with_pw {
        let reused = by_pw[p] > 1;
        let weak = strength::estimate(p).score < 3;
        let old = now - password_set_at(it, p) > OLD_AFTER_SECS;
        if reused {
            r.reused_item_ids.push(it.id.to_string());
        }
        if weak {
            r.weak_item_ids.push(it.id.to_string());
        }
        if old {
            r.old_item_ids.push(it.id.to_string());
        }
        if !(reused || weak || old) {
            clean += 1;
        }
    }
    if !with_pw.is_empty() {
        r.security_score = ((clean * 100 + with_pw.len() / 2) / with_pw.len()) as u8;
    }
    r
}
