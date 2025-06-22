package;

@:build(ssignals.Signals.build())
class Test {
	public static function main() {
		var test = new Test();
		test.onTest(x -> trace(x));
		test.test(1);
		test.test(2);
		test.test(3);
	}

	@:signal function test(x:Int);

	public function new() {}

	@:slot(test)
	function __test__(x:Int) {
		trace('Slot: ${x + 1}');
	}
}
