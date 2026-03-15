package;

class Foo {
	var b:String;

	public function new(b:String) {
		this.b = b;
	}

	public function toString() {
		return this.b + " Foo ";
	}
}

class Bar<T> {
	var c:T;

	public function new(c:T) {
		this.c = c;
	}

	public function toString() {
		return Std.string(this.c) + " Bar ";
	}
}

@:genericBuild
@:template class Edited1<T> {
	override function toString() {
		return super.toString() + "EDITED1";
	}
}

@:genericBuild
@:template class Edited2<T, B> {
	var foo:B;

	function setB(value:B) {
		var local:B = value;
		var boxed:Array<B> = [local];
		foo = boxed[0];
	}

	override function toString() {
		var a = 1;
		trace(a + 2);
		return super.toString() + "EDITED2";
	}
}

@:mixin interface BaseMixin<T> {
	public var items:Array<T>;

	public function push(value:T):Void {
		var local:T = value;
		items.push(local);
	}

	extern public function required(value:T):Void;
}

@:mixin interface DerivedMixin<U> extends BaseMixin<Array<U>> {
	public function firstLength(value:U):Int {
		var wrapped:Array<U> = [value];
		push(wrapped);
		required(wrapped);
		return items[0].length;
	}
}

class MixinImpl implements DerivedMixin<String> {
	public var items:Array<Array<String>> = [];

	public function new() {}

	public function required(value:Array<String>):Void {}
}

class MixinTest {
	public static function main() {
		var str1 = new Edited1<Foo>("Haxe is great!"); // Dynamic cannot be constructed
		trace(str1.toString()); // Haxe is great! Foo EDITED
		var str2 = new Edited1<Bar<String>>("Haxe is great!");
		trace(str2); // Haxe is great! Bar EDITED
		var str1 = new Edited2<Foo, Int>("Haxe is great!");
		trace(str1); // Haxe is great! Foo EDITED
		var str2 = new Edited2<Bar<String>, Int>("Haxe is great!");
		trace(str2); // Haxe is great! Bar EDITED
		var mixin = new MixinImpl();
		trace(mixin.firstLength("abc"));
	}
}
