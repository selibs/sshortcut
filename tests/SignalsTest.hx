package;

@:build(s.shortcut.ShortcutMacro.build())
@:autoBuild(s.shortcut.ShortcutMacro.build())
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

@:build(s.shortcut.ShortcutMacro.build())
class SignalsTest {
	@:attr static var a:Int = 0;
	@:attr static var b:Int = 0;

	@:alias static var x:Int = a;
	@:readonly @:alias static var _flush:Void->Void = flushClass;

	var i:Int;

	@:slot(aDirty)
	function __syncA__(a) {
		trace(a + i);
	}

	public function new(i:Int) {
		this.i = i;
	}

	public static function main() {
		trace(@track a + @track b);

		a = 1;
		flushClass();

		b = 2;
		flushClass();

		trace("track a + 1: " + (@track a + 1));

		a = 1;
		flushClass();

		a = 2;
		flushClass();

		var m1 = new Main(1);
		var m2 = new Main(2);

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
