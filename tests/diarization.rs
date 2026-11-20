use serde_json::json;
use vtracker::diarization::{attribution, parse_turns};
#[test]
fn multiple_voices_remain_explicit_and_sparse_overlap_stays_unknown() {
    let turns=parse_turns(&json!({"turns":[{"start_ms":0,"end_ms":100,"speaker":0},{"start_ms":100,"end_ms":200,"speaker":1}]}),200).unwrap();
    let mixed = attribution(0, 200, &turns);
    assert_eq!(mixed["speaker_status"], "multiple");
    assert!(mixed["speaker_id"].is_null());
    assert_eq!(mixed["speaker_candidates"].as_array().unwrap().len(), 2);
    assert_eq!(mixed["overlapping_speakers"], json!([]));
    assert_eq!(attribution(0, 100, &turns)["speaker_id"], "speaker_0");
    assert_eq!(attribution(190, 400, &turns)["speaker_status"], "unknown");
    assert_eq!(attribution(300, 400, &turns)["speaker_status"], "unknown");
}
#[test]
fn overlap_is_unioned_per_cluster_without_inventing_confidence() {
    let turns=parse_turns(&json!({"turns":[{"start_ms":0,"end_ms":100,"speaker":0},{"start_ms":50,"end_ms":150,"speaker":0}]}),200).unwrap();
    let result = attribution(0, 200, &turns);
    assert_eq!(result["speaker_candidates"][0]["overlap_ms"], 150);
    assert_eq!(result["speaker_id"], "speaker_0");
}
#[test]
fn malformed_model_results_are_rejected() {
    for output in [
        json!({}),
        json!({"turns":[{"start_ms":20,"end_ms":10,"speaker":0}]}),
        json!({"turns":[{"start_ms":0,"end_ms":100,"speaker":-1}]}),
        json!({"turns":[{"start_ms":0,"end_ms":1201,"speaker":0}]}),
    ] {
        assert!(parse_turns(&output, 200).is_err());
    }
    assert!(parse_turns(&json!({"turns":[]}), 200).unwrap().is_empty());
}

#[test]
fn transient_cluster_does_not_compete_with_established_voice() {
    let mut turns = parse_turns(
        &serde_json::json!({"turns":[
            {"start_ms":0,"end_ms":12000,"speaker":0},
            {"start_ms":3000,"end_ms":3400,"speaker":1},
            {"start_ms":5000,"end_ms":5500,"speaker":2},
            {"start_ms":7000,"end_ms":7500,"speaker":2},
            {"start_ms":9000,"end_ms":9500,"speaker":3},
            {"start_ms":15000,"end_ms":15500,"speaker":4}
        ]}),
        16000,
    )
    .unwrap();
    vtracker::diarization::suppress_transient_clusters(
        &mut turns,
        &[serde_json::json!({"speaker_id":"speaker_3","person_id":1})],
    );
    assert_eq!(attribution(2900, 3500, &turns)["speaker_id"], "speaker_0");
    assert_eq!(
        turns
            .iter()
            .filter(|t| t["speaker_id"] == "speaker_2")
            .count(),
        2
    );
    assert!(turns.iter().any(|t| t["speaker_id"] == "speaker_3"));
    assert!(turns.iter().any(|t| t["speaker_id"] == "speaker_4"));
}
