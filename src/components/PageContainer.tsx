import Link from "next/link";
import { IconChevron } from "./Icons";

export interface Crumb {
  label: string;
  href?: string;
}

export function Breadcrumbs({ items }: { items: Crumb[] }) {
  return (
    <nav aria-label="Breadcrumb" className="crumbs">
      <ol>
        {items.map((c, i) => (
          <li key={`${c.label}-${i}`}>
            {c.href && i < items.length - 1 ? <Link href={c.href}>{c.label}</Link> : <span aria-current={i === items.length - 1 ? "page" : undefined}>{c.label}</span>}
            {i < items.length - 1 ? <IconChevron /> : null}
          </li>
        ))}
      </ol>
    </nav>
  );
}

/** Every page: breadcrumbs, title, subtitle and the primary action in the same place. */
export function PageContainer({ title, subtitle, crumbs, actions, children }: { title: string; subtitle?: React.ReactNode; crumbs?: Crumb[]; actions?: React.ReactNode; children: React.ReactNode }) {
  return (
    <div className="page">
      <div className="page-head">
        <div>
          {crumbs ? <Breadcrumbs items={crumbs} /> : null}
          <h1 className="page-title">{title}</h1>
          {subtitle ? <p className="page-sub">{subtitle}</p> : null}
        </div>
        {actions ? <div className="page-actions">{actions}</div> : null}
      </div>
      {children}
    </div>
  );
}
