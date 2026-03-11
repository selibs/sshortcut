package;

@:build(s.shortcut.Macro.build())
class Test {
	@:track static var a:Int;

	@:alias static var x:Int = a;

	@:readonly @:alias static var _flush:Void->Void = flushClass;

	@:inject var i:Int;

	@:slot(aDirty)
	function __syncA__(a) {
		trace(a);
	}

	public function new(i:Int) {
		this.i = i;
	}

	public static function main() {
		var m1 = new Test(1);
		var m2 = new Test(2);

		a = 1;
		trace("a: " + a); // 1
		trace("x: " + x); // 1
		x = 2;
		trace("a: " + a); // 2
		trace("x: " + x); // 2

		_flush(); // 2 __syncA__ calls (3, 4)

		var t1 = new TestBar();
		var t2 = new TestBarBar();
		t1.foo(); // foo called
		t2.foo(); // overriden foo called
		TestBar.fooStatic(); // 2 foo calls (bar + overriden)
		TestBarBar.fooStatic(); // overriden foo called
	}
}

@:build(s.shortcut.Macro.build())
@:autoBuild(s.shortcut.Macro.build())
class TestFoo {
	@:signal public function foo();

	public function new(a:Int = 1) {}
}

class TestBar extends TestFoo {
	@:signal public static function fooStatic();

	@:slot(foo, fooStatic)
	function syncFoo() {
		trace("foo called");
	}
}

class TestBarBar extends TestBar {
	@:signal public static function fooStatic();

	@:slot(fooStatic)
	override function syncFoo() {
		trace("overriden foo called");
	}
}
