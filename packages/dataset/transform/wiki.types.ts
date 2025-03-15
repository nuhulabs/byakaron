
export interface WikiPage {
  title: string;
  id: string;
  ns: string;
  revision: {
      id: string;
      timestamp: string;
      contributor?: {
        username?: string;
        id?: string;
        ip?: string;
      };
      text: string;
    };
  }
  