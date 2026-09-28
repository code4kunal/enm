from __future__ import annotations

import asyncio

from app.db import SessionLocal
from app.services.id_counters import allocate_display_id


async def test_allocate_display_id_formats_and_increments() -> None:
    async with SessionLocal() as session:
        first = await allocate_display_id(
            session, kind="entry:breakdown", year=2026, prefix="BD"
        )
        second = await allocate_display_id(
            session, kind="entry:breakdown", year=2026, prefix="BD"
        )
        await session.commit()
    assert first == "BD-2026-000001"
    assert second == "BD-2026-000002"


async def test_allocate_display_id_resets_per_year() -> None:
    async with SessionLocal() as session:
        a = await allocate_display_id(
            session, kind="entry:breakdown", year=2025, prefix="BD"
        )
        b = await allocate_display_id(
            session, kind="entry:breakdown", year=2026, prefix="BD"
        )
        await session.commit()
    assert a == "BD-2025-000001"
    assert b == "BD-2026-000001"


async def test_allocate_display_id_kind_is_namespaced() -> None:
    """Entry and Ticket counters never share a sequence, even though
    Register.breakdown and TicketSourceKind.breakdown are both the string
    "breakdown" -- the `kind` argument must be the caller's full namespaced
    string, not just the raw enum value."""
    async with SessionLocal() as session:
        entry_id = await allocate_display_id(
            session, kind="entry:breakdown", year=2026, prefix="BD"
        )
        ticket_id = await allocate_display_id(
            session, kind="ticket:breakdown", year=2026, prefix="BD"
        )
        await session.commit()
    assert entry_id == "BD-2026-000001"
    assert ticket_id == "BD-2026-000001"


async def test_allocate_display_id_is_race_safe() -> None:
    async def _one() -> str:
        async with SessionLocal() as session:
            value = await allocate_display_id(
                session, kind="entry:breakdown", year=2026, prefix="BD"
            )
            await session.commit()
            return value

    results = await asyncio.gather(*[_one() for _ in range(10)])
    assert len(set(results)) == 10
