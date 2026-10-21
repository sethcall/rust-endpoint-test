fn main() {
    let built_with = option_env!("BUILT_WITH").unwrap_or("unknown (built without build.rs)");
    println!("Hello from Rust!");
    println!("Built with: {built_with}");
    println!("2 + 2 = {}", add(2, 2));
}

fn add(a: i32, b: i32) -> i32 {
    a + b
}

#[cfg(test)]
mod tests {
    #[test]
    fn adds() {
        assert_eq!(super::add(2, 2), 4);
    }
}
