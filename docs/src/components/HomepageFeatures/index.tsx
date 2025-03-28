import Heading from "@theme/Heading";
import clsx from "clsx";
import type { ReactNode } from "react";

import styles from "./styles.module.css";

type FeatureItem = {
  title: string;
  // Svg: React.ComponentType<React.ComponentProps<"svg">>;
  description: ReactNode;
};

const FeatureList: FeatureItem[] = [
  {
    title: "Bangla Text Processing",
    // Svg: require("@site/static/img/undraw_docusaurus_mountain.svg").default,
    description: (
      <>
        Process and manipulate Bangla text with ease using our comprehensive set
        of tools for text normalization, tokenization, and more.
      </>
    ),
  },
  {
    title: "NLP Capabilities",
    // Svg: require("@site/static/img/undraw_docusaurus_tree.svg").default,
    description: (
      <>
        Leverage advanced Natural Language Processing features specifically
        designed for Bangla language, including part-of-speech tagging and named
        entity recognition.
      </>
    ),
  },
  {
    title: "Developer Friendly",
    // Svg: require("@site/static/img/undraw_docusaurus_react.svg").default,
    description: (
      <>
        Built with modern development practices, Bangla Toolkit offers a clean
        API and comprehensive documentation to help you integrate Bangla
        language processing into your applications.
      </>
    ),
  },
];

function Feature({ title, Svg, description }: FeatureItem) {
  return (
    <div className={clsx("col col--4")}>
      <div className="text--center" style={{ height: "120px" }}>
        {/* <Svg className={styles.featureSvg} role="img" /> */}
      </div>
      <div className="text--center padding-horiz--md">
        <Heading as="h3">{title}</Heading>
        <p>{description}</p>
      </div>
    </div>
  );
}

export default function HomepageFeatures(): ReactNode {
  return (
    <section className={styles.features}>
      <div className="container">
        <div className="row">
          {FeatureList.map((props, idx) => (
            <Feature key={idx} {...props} />
          ))}
        </div>
      </div>
    </section>
  );
}
