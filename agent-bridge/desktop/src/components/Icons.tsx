import type { CSSProperties } from "react";

export function Icon({
  name,
  size = 16,
  style,
}: {
  name:
    | "logo"
    | "settings"
    | "close"
    | "phone"
    | "arrow"
    | "check"
    | "alert"
    | "refresh"
    | "terminal"
    | "link";
  size?: number;
  style?: CSSProperties;
}) {
  const paths = {
    logo: (
      <>
        <path d="M3 8h10M8 3v10M4.5 4.5l7 7M11.5 4.5l-7 7" />
      </>
    ),
    settings: (
      <>
        <path d="M2 4.5h2.5M7.5 4.5H14M2 11.5h6.5M11.5 11.5H14" />
        <circle cx="6" cy="4.5" r="1.5" />
        <circle cx="10" cy="11.5" r="1.5" />
      </>
    ),
    close: <path d="m4 4 8 8M12 4l-8 8" />,
    phone: (
      <>
        <rect x="4" y="1.5" width="8" height="13" rx="2" />
        <path d="M6.5 12h3" />
      </>
    ),
    arrow: <path d="m9.5 3-5 5 5 5" />,
    check: <path d="m3.5 8 3 3 6-6" />,
    alert: (
      <>
        <circle cx="8" cy="8" r="6" />
        <path d="M8 4.5v4M8 11v.5" />
      </>
    ),
    refresh: (
      <>
        <path d="M13 5.5A5.5 5.5 0 1 0 13.2 10M13 2v4H9" />
      </>
    ),
    terminal: (
      <>
        <rect x="1.5" y="2.5" width="13" height="11" rx="2" />
        <path d="m4 6 2 2-2 2M8 10h3" />
      </>
    ),
    link: (
      <>
        <path d="m6 10 4-4M5 6l1-1a3 3 0 0 1 4.2 4.2l-1 1M7 6l-1 1a3 3 0 0 0 4.2 4.2l1-1" />
      </>
    ),
  };
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      style={style}
    >
      {paths[name]}
    </svg>
  );
}
