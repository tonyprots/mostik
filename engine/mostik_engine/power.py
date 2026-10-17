"""Тепловая политика (§5): когда проверяющая выключается."""
from __future__ import annotations

import os
from dataclasses import dataclass

THERMAL_LEVELS = ("nominal", "fair", "serious", "critical")
LOW_BATTERY_PERCENT = 20


def lower_priority(step: int = 5) -> int:
    """`nice 5` для диктовки; возвращает итоговый nice."""
    try:
        return os.nice(step)
    except OSError:
        return os.nice(0)


@dataclass
class PowerState:
    thermal: str = "nominal"
    on_battery: bool = False
    low_power: bool = False
    battery: float | None = None
    battery_low: bool = False

    @classmethod
    def from_payload(cls, payload: dict) -> "PowerState":
        thermal = str(payload.get("thermal") or "nominal").lower()
        if thermal not in THERMAL_LEVELS:
            thermal = "nominal"
        battery = payload.get("battery", payload.get("battery_percent"))
        try:
            battery = float(battery) if battery is not None else None
        except (TypeError, ValueError):
            battery = None
        return cls(
            thermal=thermal,
            on_battery=bool(payload.get("on_battery", False)),
            low_power=bool(payload.get("low_power", False)),
            battery=battery,
            battery_low=bool(payload.get("battery_low", False)),
        )

    @property
    def verifier_enabled(self) -> bool:
        """Нагрев ≥ serious, энергосбережение или батарея <20% — проверяющей нет."""
        if THERMAL_LEVELS.index(self.thermal) >= THERMAL_LEVELS.index("serious"):
            return False
        if self.low_power:
            return False
        if self.on_battery and (
            self.battery_low or (self.battery is not None and self.battery < LOW_BATTERY_PERCENT)
        ):
            return False
        return True
