//! Opt-in anonymous test harness measurements; no events, SQL or parameters retained.
use std::{collections::BTreeMap, sync::{Mutex, OnceLock, atomic::{AtomicBool,Ordering}}, time::Instant};
use serde::Serialize;
#[derive(Default,Serialize)] struct Counter {calls:u64,nanoseconds:u128}
static COUNTERS: OnceLock<Mutex<BTreeMap<&'static str,Counter>>>=OnceLock::new();
static REUSE:AtomicBool=AtomicBool::new(false);
pub fn reset(reuse:bool){COUNTERS.get_or_init(Default::default).lock().unwrap().clear();REUSE.store(reuse,Ordering::Relaxed);}
pub fn reuse()->bool{cfg!(feature="statement-reuse-experiment") || REUSE.load(Ordering::Relaxed)}
pub struct Span {name:&'static str,start:Instant}
pub fn span(name:&'static str)->Span{Span{name,start:Instant::now()}}
impl Drop for Span {fn drop(&mut self){let mut c=COUNTERS.get_or_init(Default::default).lock().unwrap();let v=c.entry(self.name).or_default();v.calls+=1;v.nanoseconds+=self.start.elapsed().as_nanos();}}
pub fn snapshot()->serde_json::Value{serde_json::json!({"wallTimeNanoseconds":&*COUNTERS.get_or_init(Default::default).lock().unwrap(),"reuseUsageInsertStatement":reuse(),"contentSaved":false})}
