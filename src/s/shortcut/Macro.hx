package s.shortcut;

import haxe.macro.Compiler;
#if macro
import haxe.macro.Type;
import haxe.macro.Expr;
import haxe.macro.Context;

using haxe.macro.ExprTools;
using haxe.macro.TypeTools;
using haxe.macro.TypedExprTools;
#end

class Macro {
	#if macro
	public static function init() {
		for (m in [
			":readonly",
			":writeonly",
			":alias",
			":inject",
			":cache",
			":attr",
			":signal",
			":slot",
			"connect",
			"track",
			"bind"
		])
			Compiler.registerCustomMetadata({metadata: m, doc: "short"}, "cut");
	}

	public static function build() {
		var fields = Context.getBuildFields();

		var slots = [];
		var signals:Map<String, {isStatic:Bool, slots:Array<Expr>}> = [];

		var constructor = null;

		var flush = null;
		var classFlush = null;
		var attrs = [];
		var classAttrs = [];

		var invalid = null;
		var classInvalid = null;
		var cache = [];
		var classCache = [];

		for (field in fields.copy()) {
			switch field.kind {
				case FFun(f):
					// 	f.expr = buildConnect(f.expr);
					if (constructor == null && field.name == "new")
						constructor = f.expr;
					if (flush == null && field.name == "flush")
						flush = f.expr;
					if (classFlush == null && field.name == "flushClass")
						classFlush = f.expr;
					if (invalid == null && field.name == "invalidateCache")
						invalid = f.expr;
					if (classInvalid == null && field.name == "invalidateClassCache")
						classInvalid = f.expr;
				default:
				// case FVar(t, e):
				// 	field.kind = FVar(t, buildConnect(e));
				// case FProp(get, set, t, e):
				// 	field.kind = FProp(get, set, t, buildConnect(e));
			}
			for (m in field.meta ?? []) {
				var parts = m.name.split(".");
				switch parts[0] {
					case ":readonly":
						buildAccess(field, true, false);
					case ":writeonly":
						buildAccess(field, false, true);
					case ":alias":
						buildAlias(fields, field);
					case ":inject":
						if (m.params != null && m.params.length > 0)
							buildInject(fields, field, m.params);
					case ":signal":
						buildSignal(fields, field, signals);
					case ":slot":
						if (m.params != null && m.params.length > 0)
							slots.push({field: field, signals: m.params});
					case ":attr":
						var attr = buildAttr(fields, field, signals);
						if (field.access.contains(AStatic))
							classAttrs.push(attr);
						else
							attrs.push(attr);
					case ":cache":
						var c = buildCache(fields, field);
						if (field.access.contains(AStatic))
							classCache.push(c);
						else
							cache.push(c);
					default:
						continue;
				}
			}
		}

		if (slots.length > 0) {
			if (constructor == null) {
				var isPublic, args = [];
				var clsConstructor = findField(Context.getLocalClass()?.get(), "new");
				if (clsConstructor != null) {
					switch clsConstructor.expr().expr {
						case TFunction(tfunc):
							var v = [];
							for (a in tfunc.args)
								if (a.value != null)
									v.push(macro null)
								else {
									v.push(macro $i{a.v.name});
									args.push(({name: a.v.name} : FunctionArg));
								}
							isPublic = clsConstructor.isPublic;
							constructor = macro super($a{v});
						default:
							Context.error("Constructor must be function", clsConstructor.pos);
					}
				} else {
					isPublic = false;
					constructor = macro null;
					args = [];
				}

				fields.push({
					name: "new",
					access: isPublic ? [APublic] : [],
					kind: FFun({
						args: args,
						expr: constructor
					}),
					pos: Context.currentPos()
				});
			}

			var exprs = [{expr: constructor.expr, pos: constructor.pos}];
			for (slot in slots)
				for (signal in slot.signals) {
					switch signal.expr {
						case EConst(CIdent(s)):
							var sig = signals.get(s);
							if (sig != null && sig.isStatic && slot.field.access.contains(AStatic))
								sig.slots.push(macro $i{slot.field.name});
							else
								exprs.push(macro $signal.connect(@:pos(slot.field.pos) $i{slot.field.name}));
						default:
							exprs.push(macro $signal.connect(@:pos(slot.field.pos) $i{slot.field.name}));
					}
				}
			constructor.expr = EBlock(exprs);
		}

		buildFlush(fields, flush, classFlush, attrs, classAttrs);
		buildInvalidate(fields, invalid, classInvalid, cache, classCache);

		return fields;
	}

	static function buildConnect(expr:Expr):Expr {
		function connect(expr:Expr) {
			static var i = 0;

			var con:Array<{name:String, signal:Expr, expr:Expr}> = [];

			function replaceConnect(expr:Expr) {
				var c = connect(expr);
				if (c.connect != null)
					con = con.concat(c.connect);
				return c.expr;
			}

			if (expr == null)
				return {connect: con, expr: expr};

			switch expr.expr {
				case EFunction(kind, f):
					f.expr = buildConnect(f.expr);
				case EBlock(exprs):
					expr.expr = EBlock(exprs.map(buildConnect));
				case EFor(it, expr):
					expr.expr = EFor(replaceConnect(it), buildConnect(expr));
				case EIf(econd, eif, eelse):
					expr.expr = EIf(replaceConnect(econd), buildConnect(eif), buildConnect(eelse));
				case EWhile(econd, e, normalWhile):
					expr.expr = EWhile(replaceConnect(econd), buildConnect(e), normalWhile);
				case ESwitch(e, cases, edef):
					expr.expr = ESwitch(replaceConnect(e), cases.map(c -> {
						values: c.values,
						guard: c.guard,
						expr: buildConnect(c.expr)
					}), buildConnect(edef));
				case ETry(e, catches):
					expr.expr = ETry(replaceConnect(e), catches.map(c -> {
						name: c.name,
						type: c.type,
						expr: buildConnect(c.expr)
					}));
				case ETernary(econd, eif, eelse):
					expr.expr = ETernary(replaceConnect(econd), buildConnect(eif), buildConnect(eelse));
				case EMeta(s, e):
					var signal = switch s.name {
						case "connect":
							e;
						case "track":
							makeIdent(e, "Dirty");
						case "bind":
							makeIdent(e, "Changed");
						default:
							expr = expr.map(replaceConnect);
					}
					if (signal != null) {
						expr.expr = e.expr;
						con.push({name: "__c" + i++, signal: signal, expr: expr});
					}
				default:
					expr = expr.map(replaceConnect);
			}
			return {connect: con, expr: expr}
		}

		function rename(expr:Expr, target:Expr, name:String)
			return expr == target ? macro @:pos(expr.pos) $i{name} : expr.map(e -> rename(e, target, name));

		var con = connect(expr);
		if (con.connect.length > 0) {
			var exprs = [];
			for (c in con.connect) {
				var name = c.name;
				var signal = c.signal;
				exprs.push(macro $signal.connect($name -> ${rename(expr, c.expr, name)}));
			}
			return macro @:pos(expr.pos) $b{exprs};
		}
		
		return con.expr;
	}

	static function buildAccess(field:Field, read:Bool, write:Bool) {
		switch field.kind {
			case FVar(t, e):
				field.kind = FProp(read ? "default" : "never", write ? "default" : "never", t, e);
			case FProp(get, set, t, e):
				if (!read)
					get = "never";
				if (!write)
					set = "never";
				field.kind = FProp(get, set, t, e);
			case FFun(f):
				Context.error("Can't change function access", field.pos);
		}
	}

	static function buildAlias(fields:Array<Field>, field:Field) {
		switch field.kind {
			case FVar(t, e):
				field.kind = FProp("get", "set", t, e);
				buildAlias(fields, field);
			case FProp(get, set, t, e):
				if (e == null)
					Context.error("Alias expression expected", field.pos);
				if (t == null)
					Context.error("Alias must be type-hinted", field.pos);

				field.kind = FProp(get == "default" ? "get" : get, set == "default" ? "set" : set, t, null);
				injectProp(fields, field, r -> macro return $e, r -> macro return $e = $r, true);
				if (!field.access.contains(AExtern))
					field.access.push(AExtern);
			case FFun(f):
				Context.error("Functions can't be aliases", field.pos);
		}
	}

	static function buildInject(fields:Array<Field>, field:Field, injections:Array<Expr>) {
		switch field.kind {
			case FVar(t, e):
				field.kind = FProp("default", "set", t, e);
				buildInject(fields, field, injections);
			case FProp(get, set, t, e):
				if (set != "null" && set != "set" && set != "default")
					Context.error('Can\'t inject property with $set write access', field.pos);
				var canRead = get != "never";
				var setterName = "set_" + field.name;
				for (f in fields)
					if (f.name == setterName) {
						buildInject(fields, f, injections);
						return;
					}

				var setter = {
					name: setterName,
					access: [APrivate].concat(field.access.contains(AStatic) ? [AStatic] : []),
					kind: FFun({
						args: [{name: "value", type: t}],
						expr: canRead ? macro return $i{field.name} = value : macro return value
					}),
					pos: field.pos
				}
				fields.push(setter);
				buildInject(fields, setter, injections);
			case FFun(f):
				var injection = macro $b{injections};
				f.expr = f.expr != null ? injectReturn(f.expr, injection) : injection;
		}
	}

	static function buildSignal(fields:Array<Field>, field:Field, signals:Map<String, {isStatic:Bool, slots:Array<Expr>}>) {
		var slots = [];
		var slotsExpr = {
			expr: EArrayDecl(slots),
			pos: field.pos
		}
		switch field.kind {
			case FFun(f):
				if (f.expr != null)
					Context.warning("Signals can't have expressions", f.expr.pos);
				var slotT:ComplexType = TFunction([
					for (a in f.args) {
						if (a.type == null) Context.error("Signal arguments must be type-hinted", field.pos);
						var named = TNamed(a.name, a.type);
						a.opt ? TOptional(named) : named;
					}
				], macro :Void);
				field.kind = FProp("default", "never", macro :s.shortcut.Signal<$slotT>, macro new s.shortcut.Signal($slotsExpr));
				// sugar
				var name = field.name.charAt(0).toUpperCase() + field.name.substr(1);
				for (f in ["on" => "", "off" => "dis"].keyValueIterator()) {
					var m = f.value + "connect";
					fields.push({
						name: f.key + name,
						access: field.access.concat(field.access.contains(AInline) ? [] : [AInline]).concat(field.access.contains(AExtern) ? [] : [AExtern]),
						kind: FFun({
							args: [{name: "slot", type: slotT}],
							expr: macro $i{field.name}.$m(slot)
						}),
						pos: field.pos
					});
				}
			case FVar(t, _), FProp(_, _, t, _):
				var signalName = field.name + "Changed";
				injectProp(fields, field, r -> macro {$i{signalName}($r); return $r;});
				var signal:Field = {
					access: field.access,
					name: signalName,
					kind: FFun({args: [{name: field.name, type: t}]}),
					pos: field.pos
				};
				fields.push(signal);
				buildSignal(fields, signal, signals);
		}

		signals.set(field.name, {
			isStatic: field.access.contains(AStatic),
			slots: slots
		});
	}

	static function buildAttr(fields:Array<Field>, field:Field, signals:Map<String, {isStatic:Bool, slots:Array<Expr>}>) {
		// marker
		var markerName = field.name + "IsDirty";
		var markerRef = macro $i{markerName};
		var marker = macro if (!$markerRef) $markerRef = true;
		fields.push({
			name: markerName,
			access: field.access.contains(AStatic) ? [AStatic] : [],
			kind: FProp("default", "null", macro :Bool, macro false),
			pos: field.pos
		});

		var refName = field.name.charAt(0).toUpperCase() + field.name.substr(1);
		var valName, signalName, signalType;
		switch field.kind {
			case FVar(t, e), FProp(_, _, t, e):
				valName = field.name;
				signalName = valName + "Dirty";
				signalType = t;
				injectProp(fields, field, null, r -> macro {$marker; return $r;});
			case FFun(f):
				if (f.expr == null)
					Context.error("Can't track function with no expression", field.pos);
				if (f.ret == null)
					Context.error("Missing return type", field.pos);
				// cache
				valName = field.name + "Cached";
				signalName = field.name + "Called";
				signalType = f.ret;
				fields.push({
					name: valName,
					access: field.access.contains(AStatic) ? [AStatic] : [],
					kind: FProp("default", "null"),
					pos: field.pos
				});
				f.expr = injectReturn(f.expr, macro {$i{valName} = __r; $marker;});
		}

		// signal
		var signal = {
			name: signalName,
			access: field.access,
			kind: FFun({args: [{name: field.name, type: signalType}]}),
			pos: field.pos
		}
		buildSignal(fields, signal, signals);
		fields.push(signal);

		return macro if ($markerRef) {
			$markerRef = false;
			$i{signalName}($i{valName});
		}
	}

	static function buildFlush(fields:Array<Field>, flush:Expr, classFlush:Expr, attrs:Array<Expr>, classAttrs:Array<Expr>) {
		if (attrs.length > 0) {
			if (flush == null)
				if (fieldExists(Context.getLocalClass()?.get(), "flush"))
					flush = macro super.flush();
				else
					flush = macro null;
			attrs.unshift(flush);
			fields.push({
				name: "flush",
				kind: FFun({
					args: [],
					expr: macro $b{attrs}
				}),
				pos: Context.currentPos()
			});
		}

		if (classAttrs.length > 0)
			classAttrs.unshift(classFlush ?? macro null);
		if (classAttrs.length > 0)
			fields.push({
				name: "flushClass",
				access: [AStatic],
				kind: FFun({
					args: [],
					expr: macro $b{classAttrs}
				}),
				pos: Context.currentPos()
			});
	}

	static function buildCache(fields:Array<Field>, field:Field) {
		var cacheName = field.name + "Cached";
		switch field.kind {
			case FVar(t, _), FProp(_, _, t, _):
				fields.push({
					name: cacheName,
					access: field.access,
					kind: FProp("default", "null", t, macro $i{field.name}),
					pos: field.pos
				});
			case FFun(f):
				Context.error("Can't cache function", field.pos);
		}
		return macro if ($i{cacheName} != $i{field.name}) $i{cacheName} = $i{field.name};
	}

	static function buildInvalidate(fields:Array<Field>, invalid:Expr, classInvalid:Expr, cache:Array<Expr>, classCache:Array<Expr>) {
		if (cache.length > 0) {
			if (invalid == null)
				if (fieldExists(Context.getLocalClass()?.get(), "invalidateCache"))
					invalid = macro super.invalidateCache();
				else
					invalid = macro null;
			cache.unshift(invalid);
			fields.push({
				name: "invalidateCache",
				kind: FFun({
					args: [],
					expr: macro $b{cache}
				}),
				pos: Context.currentPos()
			});
		}

		if (classCache.length > 0)
			classCache.unshift(classInvalid ?? macro null);
		if (classCache.length > 0)
			fields.push({
				name: "invalidateClassCache",
				access: [AStatic],
				kind: FFun({
					args: [],
					expr: macro $b{classCache}
				}),
				pos: Context.currentPos()
			});
	}

	static function fieldExists(cls:ClassType, name:String) {
		return findField(cls, name) != null;
	}

	static function findField(cls:ClassType, name:String) {
		if (cls == null)
			return null;
		if (name == "new") {
			var field = cls.constructor?.get();
			if (field != null)
				return field;
		}
		var field = cls.findField(name);
		if (field != null)
			return field;
		return findField(cls.superClass?.t.get(), name);
	}

	static function injectProp(fields:Array<Field>, field:Field, ?getExpr:Expr->Expr, ?setExpr:Expr->Expr, isExtern:Bool = false) {
		function pushAccessor(name:String, fun:Function) {
			var access = [APrivate];
			if (field.access.contains(AStatic))
				access.push(AStatic);
			if (isExtern) {
				access.push(AExtern);
				access.push(AInline);
			}
			fields.push({
				access: access,
				name: name,
				kind: FFun(fun),
				pos: field.pos
			});
		}

		switch field.kind {
			case FVar(t, e):
				field.kind = FProp(getExpr != null ? "get" : "default", setExpr != null ? "set" : "default", t, e);
				injectProp(fields, field, getExpr, setExpr);
			case FProp(get, set, t, e):
				var isVar = false;
				for (m in field.meta)
					if (m.name == ":isVar") {
						isVar = true;
						break;
					}
				if (!isVar)
					isVar = get == "default" || set == "default";

				if (get != "get" && get != "null" && get != "default")
					getExpr = null;

				if (set != "set" && set != "null" && set != "default")
					setExpr = null;

				field.kind = FProp(get, set, t, e);

				var getterName = "get_" + field.name;
				var setterName = "set_" + field.name;
				var getter:Function = null;
				var setter:Function = null;
				for (f in fields)
					switch f.kind {
						case FFun(fn):
							if (f.name == getterName || f.name == setterName) {
								if (fn.expr == null)
									Context.error("Function requires a body", f.pos);
								if (f.name == getterName)
									getter = fn;
								else
									setter = fn;
							}
						default: continue;
					}

				if (getExpr != null) {
					if (getter == null) {
						getter = {
							args: [],
							ret: t,
							expr: isVar ? macro return $i{field.name} : null
						}
						pushAccessor(getterName, getter);
					}
					getter.expr = getter.expr != null ? replaceReturn(getter.expr, getExpr) : getExpr(null);
				}

				if (setExpr != null) {
					if (setter == null) {
						setter = {
							args: [{name: "value", type: t}],
							ret: t,
							expr: isVar ? macro return $i{field.name} = value : macro return value
						}
						pushAccessor(setterName, setter);
					}
					setter.expr = replaceReturn(setter.expr, setExpr);
				}
			case _:
				Context.error("Property expected", field.pos);
		}
	}

	static function injectReturn(e1:Expr, e2:Expr):Expr {
		return replaceReturn(e1, r -> macro {$e2; ${r == null ?macro return:macro return $r}});
	}

	static function replaceReturn(e1:Expr, e2:Expr->Expr) {
		var replaced = false;

		function replace(expr:Expr) {
			return switch expr.expr {
				case EFunction(_, _): expr;
				case EReturn(v):
					replaced = true;
					if (v == null) e2(null) else macro {
						final __r = $v;
						${e2(macro __r)};
					}
				default: expr.map(replace);
			}
		}

		var expr = replace(e1);
		if (replaced)
			return expr;

		return macro {
			final __r = $e1;
			${e2(macro __r)};
		};
	}

	static function makeIdent(expr:Expr, ?add:String) {
		add = add ?? "";
		return switch expr.expr {
			case EConst(CIdent(s)):
				macro @:pos(expr.pos) $i{s + add};
			case EField(e, field, kind):
				field += add;
				macro @:pos(expr.pos) ${makeIdent(e)}.$field;
			default:
				Context.error("Identifier expected", expr.pos);
				null;
		}
	}
	#end
}
