import Link from "@docusaurus/Link";
import { useColorMode } from "@docusaurus/theme-common";
import useDocusaurusContext from "@docusaurus/useDocusaurusContext";
import HomepageFeatures from "@site/src/components/HomepageFeatures";
import Heading from "@theme/Heading";
import Layout from "@theme/Layout";
import clsx from "clsx";
import type { ReactNode } from "react";

import styles from "./index.module.css";

function HomepageHeader() {
  const { siteConfig } = useDocusaurusContext();
  const { colorMode } = useColorMode();
  const isDarkTheme = colorMode === "dark";
  return (
    <header className={clsx("hero hero", styles.heroBanner)}>
      <div className="container">
        <div
          style={{
            display: "flex",
            flexDirection: "row",
            gap: "30px",
            alignItems: "center",
            justifyContent: "center",
          }}
        >
          <img
            src="/core/img/mascot-main.svg"
            alt="Bangla Toolkit Logo"
            style={{
              height: "min(250px, 35vw)",
              objectFit: "contain",
            }}
          />
          <img
            src="/core/img/logo.svg"
            alt="Bangla Toolkit Logo"
            style={{
              height: "min(220px, 30vw)",
              filter: isDarkTheme ? "brightness(10)" : "brightness(0)", // White in dark mode, black in light mode
            }}
          />
        </div>
        <br />
        <hr
          style={{
            width: "50%",
            margin: "0 auto",
            marginTop: "20px",
            marginBottom: "20px",
            border: "5px solid #e0e0e0",
            borderRadius: "10px",
          }}
        />
        <Heading as="h1" className="hero__title">
          {siteConfig.title}
        </Heading>
        <p className="hero__subtitle">{siteConfig.tagline}</p>
        <div className={styles.buttons}>
          <Link
            className="button button--secondary button--lg"
            to="/docs/intro"
          >
            Introduction
          </Link>

          <Link
            className="button button--secondary button--lg"
            to="/docs/getting-started"
          >
            Get Started
          </Link>
        </div>
      </div>
    </header>
  );
}

export default function Home(): ReactNode {
  const { siteConfig } = useDocusaurusContext();
  return (
    <Layout
      title={`${siteConfig.title}`}
      description="Description will go into a meta tag in <head />"
    >
      <HomepageHeader />
      <main>
        <HomepageFeatures />
      </main>
    </Layout>
  );
}
