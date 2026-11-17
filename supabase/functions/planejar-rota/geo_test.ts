import { assertEquals } from "jsr:@std/assert@1";
import { lerEwkbHex, lerPonto } from "./geo.ts";

Deno.test("lerPonto interpreta EWKB hex (little endian, com SRID)", () => {
  const c = lerPonto("0101000020E6100000A69BC420B06247C02B8716D9CE8737C0");
  assertEquals(c, { lng: -46.771, lat: -23.5305 });
});

Deno.test("lerEwkbHex interpreta WKB big endian sem SRID", () => {
  assertEquals(lerEwkbHex("0000000001C04762B020C49BA6C03787CED916872B"), { lng: -46.771, lat: -23.5305 });
});

Deno.test("lerEwkbHex rejeita texto que nao e ponto", () => {
  assertEquals(lerEwkbHex("POINT(1 2)"), null);
  assertEquals(lerEwkbHex("0102"), null);
});
