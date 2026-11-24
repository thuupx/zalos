use zalos_vault::*;

const SLOT: &str = "slot-abc";

fn root() -> [u8; 32] {
    generate_root()
}

#[test]
fn seal_open_round_trip_root_and_box() {
    let r = root();
    let pk = derive_public_key(&r, SLOT).unwrap();
    let pt = b"hello vault";
    let sealed = seal(&pk, b"aad", pt).unwrap();
    assert_ne!(&sealed[32..], pt); // ciphertext after the encapped key

    let opened = open_with_root(&r, SLOT, b"aad", &sealed).unwrap();
    assert_eq!(opened, pt);

    // box key path: wrap to a device box key
    let kp = box_keypair();
    let wrapped = seal(&kp.public, b"box", &r).unwrap();
    let unwrapped = open_with_private(&kp.private, b"box", &wrapped).unwrap();
    assert_eq!(unwrapped, r);
}

#[test]
fn wrong_root_slot_aad_tamper_fail() {
    let r = root();
    let pk = derive_public_key(&r, SLOT).unwrap();
    let sealed = seal(&pk, b"aad", b"data").unwrap();

    assert!(open_with_root(&root(), SLOT, b"aad", &sealed).is_err());
    assert!(open_with_root(&r, "other-slot", b"aad", &sealed).is_err());
    assert!(open_with_root(&r, SLOT, b"other-aad", &sealed).is_err());

    let mut bad = sealed.clone();
    let last = bad.len() - 1;
    bad[last] ^= 1;
    assert!(open_with_root(&r, SLOT, b"aad", &bad).is_err());
    assert!(open_with_root(&r, SLOT, b"aad", &sealed[..10]).is_err());
}

#[test]
fn derive_public_key_deterministic_per_slot() {
    let r = root();
    assert_eq!(
        derive_public_key(&r, SLOT).unwrap(),
        derive_public_key(&r, SLOT).unwrap()
    );
    assert_ne!(
        derive_public_key(&r, SLOT).unwrap(),
        derive_public_key(&r, "slot-xyz").unwrap()
    );
}

#[test]
fn file_round_trip_and_sequence_enforced() {
    let r = root();
    let pk = derive_public_key(&r, SLOT).unwrap();
    let (mut sealer, header) = FileSealer::new(&pk, b"file-aad").unwrap();
    assert_eq!(header.len(), 32);

    let chunks: Vec<Vec<u8>> = (0..5)
        .map(|i| vec![i as u8; 1024 * 1024])
        .collect();
    let sealed: Vec<Vec<u8>> = chunks
        .iter()
        .map(|c| sealer.seal_chunk(c).unwrap())
        .collect();
    for (i, s) in sealed.iter().enumerate() {
        assert_eq!(s.len(), chunks[i].len() + 16);
    }

    let mut opener = FileOpener::with_root(&r, SLOT, b"file-aad", &header).unwrap();
    for (i, s) in sealed.iter().enumerate() {
        assert_eq!(opener.open_chunk(s).unwrap(), chunks[i]);
    }

    // reordered chunk fails
    let mut op2 = FileOpener::with_root(&r, SLOT, b"file-aad", &header).unwrap();
    assert!(op2.open_chunk(&sealed[1]).is_err());
    // duplicated chunk fails
    let mut op3 = FileOpener::with_root(&r, SLOT, b"file-aad", &header).unwrap();
    assert!(op3.open_chunk(&sealed[0]).is_ok());
    assert!(op3.open_chunk(&sealed[0]).is_err());
    // dropped middle: last chunk at wrong position fails
    let mut op4 = FileOpener::with_root(&r, SLOT, b"file-aad", &header).unwrap();
    assert!(op4.open_chunk(&sealed[0]).is_ok());
    assert!(op4.open_chunk(&sealed[4]).is_err());
    // a different (box) private key cannot open the file
    let kp2 = box_keypair();
    let mut op5 = FileOpener::with_private(&kp2.private, b"file-aad", &header).unwrap();
    assert!(op5.open_chunk(&sealed[0]).is_err());
}

#[test]
fn seal_is_probabilistic() {
    let r = root();
    let pk = derive_public_key(&r, SLOT).unwrap();
    let a = seal(&pk, b"", b"same").unwrap();
    let b = seal(&pk, b"", b"same").unwrap();
    assert_ne!(a, b);
}

#[test]
fn fingerprint_format() {
    let r = root();
    let pk = derive_public_key(&r, SLOT).unwrap();
    let fp = fingerprint(&pk);
    assert_eq!(fp.len(), 8 * 4 + 7);
    assert!(fp.chars().all(|c| c.is_ascii_hexdigit() || c == ' '));
}

#[test]
fn file_round_trip_via_box_private() {
    let kp = box_keypair();
    let (mut s2, h2) = FileSealer::new(&kp.public, b"file-aad").unwrap();
    let c = s2.seal_chunk(b"x").unwrap();
    let mut o = FileOpener::with_private(&kp.private, b"file-aad", &h2).unwrap();
    assert_eq!(o.open_chunk(&c).unwrap(), b"x");
}

#[test]
fn versioned_key_rotation_isolates_generations() {
    let r = root();
    let pk1 = derive_public_key(&r, SLOT).unwrap();
    let pk1_explicit = derive_public_key_version(&r, SLOT, 1).unwrap();
    let pk2 = derive_public_key_version(&r, SLOT, 2).unwrap();
    assert_eq!(pk1, pk1_explicit);
    assert_ne!(pk1, pk2);

    let sealed_v1 = seal(&pk1, b"aad", b"gen1").unwrap();
    let sealed_v2 = seal(&pk2, b"aad", b"gen2").unwrap();

    assert_eq!(open_with_root_version(&r, SLOT, 1, b"aad", &sealed_v1).unwrap(), b"gen1");
    assert_eq!(open_with_root_version(&r, SLOT, 2, b"aad", &sealed_v2).unwrap(), b"gen2");
    assert!(open_with_root_version(&r, SLOT, 2, b"aad", &sealed_v1).is_err());
    assert!(open_with_root_version(&r, SLOT, 1, b"aad", &sealed_v2).is_err());
}
