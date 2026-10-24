---
paths: ["src/components/**/*.tsx"]
---
# React components

- **Components don't fetch.** Data comes from props or from a hook in
  `src/hooks/`. A component never calls `fetch` or an API client itself.

  Bad:

  ```tsx
  export function OrderList() {
    const [orders, setOrders] = useState<Order[]>([]);
    useEffect(() => {
      fetch("/api/orders").then((r) => r.json()).then(setOrders);
    }, []);
    return <ul>{orders.map((o) => <OrderRow key={o.id} order={o} />)}</ul>;
  }
  ```

  Good:

  ```tsx
  export function OrderList() {
    const { orders } = useOrders();
    return <ul>{orders.map((o) => <OrderRow key={o.id} order={o} />)}</ul>;
  }
  ```

- **No `any`.** Use `unknown` and narrow it, or write the type.

  Bad:

  ```tsx
  function Price({ value }: { value: any }) {
    return <span>{value.toFixed(2)}</span>;
  }
  ```

  Good:

  ```tsx
  function Price({ value }: { value: number }) {
    return <span>{value.toFixed(2)}</span>;
  }
  ```

- **Text users see goes through `t()`.** No English strings written directly
  in JSX, so every screen can be translated. Values from data, like
  `user.name`, aren't text we write, so they're fine.

  Bad:

  ```tsx
  function EmptyCart() {
    return <p>Your cart is empty. Keep shopping!</p>;
  }
  ```

  Good:

  ```tsx
  function EmptyCart() {
    const { t } = useTranslation();
    return <p>{t("cart.empty")}</p>;
  }
  ```
