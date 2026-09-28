from __future__ import annotations

from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.id_counter import IdCounter


async def allocate_display_id(
    session: AsyncSession, *, kind: str, year: int, prefix: str
) -> str:
    """Atomically hands out the next `<prefix>-<year>-<NNNNNN>` for this
    kind+year. `kind` must already be namespaced by the caller
    (`entry:breakdown`, `ticket:breakdown`, ...) -- Entry and Ticket never
    share a counter even where the underlying enum string is identical.

    The upsert always increments `next_value`, then we hand back one less
    than what we stored -- avoids a second round trip to read-then-write.
    """
    stmt = (
        pg_insert(IdCounter)
        .values(kind=kind, year=year, next_value=2)
        .on_conflict_do_update(
            index_elements=[IdCounter.kind, IdCounter.year],
            set_={"next_value": IdCounter.next_value + 1},
        )
        .returning(IdCounter.next_value)
    )
    result = await session.execute(stmt)
    allocated = result.scalar_one() - 1
    return f"{prefix}-{year}-{allocated:06d}"
