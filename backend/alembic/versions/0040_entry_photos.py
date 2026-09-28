"""entry_photos -- one-to-many, replaces entries.photo_key/photo_url.

Revision ID: 0040
Revises: 0039
Create Date: 2026-09-28
"""
from __future__ import annotations

import uuid

from alembic import op
import sqlalchemy as sa

revision = "0040"
down_revision = "0039"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "entry_photos",
        sa.Column("id", sa.String(length=32), primary_key=True),
        sa.Column(
            "entry_id", sa.String(length=32),
            sa.ForeignKey("entries.id", ondelete="CASCADE"), nullable=False,
        ),
        sa.Column("storage_key", sa.String(length=255), nullable=False),
        sa.Column("url", sa.String(length=500), nullable=False),
        sa.Column("caption", sa.String(length=255), nullable=True),
        sa.Column(
            "uploaded_by_id", sa.String(length=32),
            sa.ForeignKey("users.id", ondelete="SET NULL"), nullable=True,
        ),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    conn = op.get_bind()
    rows = conn.execute(
        sa.text(
            "SELECT id, photo_key, photo_url FROM entries WHERE photo_key IS NOT NULL"
        )
    ).fetchall()
    for entry_id, photo_key, photo_url in rows:
        conn.execute(
            sa.text(
                "INSERT INTO entry_photos (id, entry_id, storage_key, url, created_at) "
                "VALUES (:id, :entry_id, :key, :url, now())"
            ),
            {"id": uuid.uuid4().hex, "entry_id": entry_id, "key": photo_key, "url": photo_url},
        )
    op.drop_column("entries", "photo_key")
    op.drop_column("entries", "photo_url")


def downgrade() -> None:
    op.add_column("entries", sa.Column("photo_url", sa.String(length=1024), nullable=True))
    op.add_column("entries", sa.Column("photo_key", sa.String(length=255), nullable=True))
    conn = op.get_bind()
    rows = conn.execute(
        sa.text(
            "SELECT DISTINCT ON (entry_id) entry_id, storage_key, url "
            "FROM entry_photos ORDER BY entry_id, created_at"
        )
    ).fetchall()
    for entry_id, storage_key, url in rows:
        conn.execute(
            sa.text(
                "UPDATE entries SET photo_key = :key, photo_url = :url WHERE id = :id"
            ),
            {"key": storage_key, "url": url, "id": entry_id},
        )
    op.drop_table("entry_photos")
