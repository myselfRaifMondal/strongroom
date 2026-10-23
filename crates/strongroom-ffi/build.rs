fn main() {
    uniffi::generate_scaffolding("src/strongroom.udl").expect("UDL scaffolding");
}
